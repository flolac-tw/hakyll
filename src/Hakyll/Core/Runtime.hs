--------------------------------------------------------------------------------
module Hakyll.Core.Runtime
    ( run
    ) where


--------------------------------------------------------------------------------
import           Control.Applicative           ((<$>))
import           Control.Monad                 (filterM)
import           Control.Monad.Error           (ErrorT, runErrorT, throwError)
import           Control.Monad.Reader          (ask)
import           Control.Monad.RWS             (RWST, runRWST)
import           Control.Monad.State           (get, modify)
import           Control.Monad.Trans           (liftIO)
import           Data.Map                      (Map)
import qualified Data.Map                      as M
import           Data.Monoid                   (mempty)
import           Data.Set                      (Set)
import qualified Data.Set                      as S
import           System.FilePath               ((</>))


--------------------------------------------------------------------------------
import           Hakyll.Core.CompiledItem
import           Hakyll.Core.Compiler.Internal
import           Hakyll.Core.Configuration
import           Hakyll.Core.Dependencies
import           Hakyll.Core.Identifier
import           Hakyll.Core.Logger
import           Hakyll.Core.ResourceProvider
import           Hakyll.Core.Routes
import           Hakyll.Core.Rules.Internal
import           Hakyll.Core.Store             (Store)
import qualified Hakyll.Core.Store             as Store
import           Hakyll.Core.Util.File
import           Hakyll.Core.Writable


--------------------------------------------------------------------------------
run :: Configuration -> Rules a -> IO RuleSet
run configuration rules = do
    -- Initialization
    logger <- makeLogger putStrLn
    section logger "Initialising"
    store    <- timed logger "Creating store" $
        Store.new (inMemoryCache configuration) $ storeDirectory configuration
    provider <- timed logger "Creating provider" $
        newResourceProvider store (ignoreFile configuration) "."
    ruleSet  <- timed logger "Running rules" $ runRules rules provider

    -- Get old facts
    mOldFacts <- Store.get store factsKey
    let (oldFacts) = case mOldFacts of Store.Found f -> f
                                       _             -> mempty

    -- Build runtime read/state
    let compilers = rulesCompilers ruleSet
        read'     = RuntimeRead
            { runtimeConfiguration = configuration
            , runtimeLogger        = logger
            , runtimeProvider      = provider
            , runtimeStore         = store
            , runtimeRoutes        = rulesRoutes ruleSet
            , runtimeUniverse      = compilers
            }
        state     = RuntimeState
            { runtimeDone  = S.empty
            , runtimeTodo  = M.empty
            , runtimeFacts = oldFacts
            }

    -- Run the program and fetch the resulting state
    result <- runErrorT $ runRWST build read' state
    case result of
        Left e          -> thrown logger e
        Right (_, s, _) -> Store.set store factsKey $ runtimeFacts s

    -- Flush and return
    flushLogger logger
    return ruleSet
  where
    factsKey = ["Hakyll.Core.Runtime.run", "facts"]


--------------------------------------------------------------------------------
data RuntimeRead = RuntimeRead
    { runtimeConfiguration :: Configuration
    , runtimeLogger        :: Logger
    , runtimeProvider      :: ResourceProvider
    , runtimeStore         :: Store
    , runtimeRoutes        :: Routes
    , runtimeUniverse      :: [(Identifier, Compiler CompiledItem)]
    }


--------------------------------------------------------------------------------
data RuntimeState = RuntimeState
    { runtimeDone  :: Set Identifier
    , runtimeTodo  :: Map Identifier (Compiler CompiledItem)
    , runtimeFacts :: DependencyFacts
    }


--------------------------------------------------------------------------------
type Runtime a = RWST RuntimeRead () RuntimeState (ErrorT String IO) a


--------------------------------------------------------------------------------
build :: Runtime ()
build = do
    scheduleOutOfDate
    pickAndChase


--------------------------------------------------------------------------------
scheduleOutOfDate :: Runtime ()
scheduleOutOfDate = do
    logger   <- runtimeLogger   <$> ask
    provider <- runtimeProvider <$> ask
    universe <- runtimeUniverse <$> ask
    facts    <- runtimeFacts    <$> get
    todo     <- runtimeTodo     <$> get

    let identifiers = map fst universe
    modified <- timed logger "Checking for modified items" $
        fmap S.fromList $ flip filterM identifiers $
            liftIO . resourceModified provider
    let (ood, facts', _) = outOfDate identifiers modified facts
        todo'            = M.fromList
            [(id', c) | (id', c) <- universe, id' `S.member` ood]

    -- Update facts and todo items
    modify $ \s -> s
        { runtimeTodo  = todo `M.union` todo'
        , runtimeFacts = facts'
        }


--------------------------------------------------------------------------------
pickAndChase :: Runtime ()
pickAndChase = do
    todo <- runtimeTodo <$> get
    case M.minViewWithKey todo of
        Nothing            -> return ()
        Just ((id', _), _) -> chase [] id'


--------------------------------------------------------------------------------
chase :: [Identifier] -> Identifier -> Runtime ()
chase trail id'
    | id' `elem` trail = return ()  -- Cycle detected!
    | otherwise        = do
        logger   <- runtimeLogger        <$> ask
        todo     <- runtimeTodo          <$> get
        provider <- runtimeProvider      <$> ask
        universe <- runtimeUniverse      <$> ask
        routes   <- runtimeRoutes        <$> ask
        store    <- runtimeStore         <$> ask
        config   <- runtimeConfiguration <$> ask

        section logger $ "Processing " ++ show id'
        isModified <- liftIO $ resourceModified provider id'
        let compiler = todo M.! id'
            read' = CompilerRead
                { compilerIdentifier       = id'
                , compilerResourceProvider = provider
                , compilerUniverse         = map fst universe
                , compilerRoutes           = routes
                , compilerStore            = store
                , compilerResourceModified = isModified
                , compilerLogger           = logger
                }

        result <- timed logger "Compiling" $ liftIO $ runCompiler compiler read'
        case result of
            -- Rethrow error
            CompilerError e -> throwError e

            -- Huge success
            CompilerDone compiled facts -> do
                -- Write if necessary
                case runRoutes routes id' of
                    Nothing  -> return ()
                    Just url -> timed logger ("Routing to " ++ url) $ do
                        let path = destinationDirectory config </> url
                        liftIO $ makeDirectories path
                        liftIO $ write path compiled

                -- Update state
                modify $ \s -> s
                    { runtimeDone  = S.insert id' (runtimeDone s)
                    , runtimeTodo  = M.delete id' (runtimeTodo s)
                    , runtimeFacts = M.insert id' facts (runtimeFacts s)
                    }

            -- Try something else first
            CompilerRequire dep c -> do
                -- Update the compiler so we don't execute it twice
                depDone <- (dep `S.member`) . runtimeDone <$> get
                modify $ \s -> s
                    { runtimeTodo = M.insert id'
                        (if depDone then c else compilerResult result)
                        (runtimeTodo s)
                    }

                -- If the required item is already compiled, continue, or, start
                -- chasing that
                if depDone then chase trail id' else chase (id' : trail) dep