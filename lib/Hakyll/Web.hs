--------------------------------------------------------------------------------
-- | A top-level module exporting all Hakyll.Web modules
{-# LANGUAGE CPP #-}
module Hakyll.Web
    ( module Hakyll.Web.CompressCss
    , module Hakyll.Web.Feed
    , module Hakyll.Web.Html
    , module Hakyll.Web.Html.RelativizeUrls
    , module Hakyll.Web.Paginate
#ifdef USE_PANDOC
    , module Hakyll.Web.Pandoc
    , module Hakyll.Web.Pandoc.Biblio
    , module Hakyll.Web.Pandoc.FileType
#endif
    , module Hakyll.Web.Redirect
    , module Hakyll.Web.Tags
    , module Hakyll.Web.Template
    , module Hakyll.Web.Template.Context
    , module Hakyll.Web.Template.List
    ) where


--------------------------------------------------------------------------------
import           Hakyll.Web.CompressCss
import           Hakyll.Web.Feed
import           Hakyll.Web.Html
import           Hakyll.Web.Html.RelativizeUrls
import           Hakyll.Web.Paginate
#ifdef USE_PANDOC
import           Hakyll.Web.Pandoc
import           Hakyll.Web.Pandoc.Biblio
import           Hakyll.Web.Pandoc.FileType
#endif
import           Hakyll.Web.Redirect
import           Hakyll.Web.Tags
import           Hakyll.Web.Template
import           Hakyll.Web.Template.Context
import           Hakyll.Web.Template.List
