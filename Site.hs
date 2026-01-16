{-# LANGUAGE OverloadedStrings #-}

import Data.Monoid (mappend)
import qualified Data.Text as T
import Hakyll
import Text.Pandoc
import Text.Pandoc.Options
import Scripta (processScripta)

main :: IO ()
main = hakyll $ do
    -- Static files
    match "media/images/**" $ do
        route   idRoute
        compile copyFileCompiler

    match "media/audio/*" $ do
        route   idRoute
        compile copyFileCompiler

    match "media/video/*" $ do
        route   idRoute
        compile copyFileCompiler

    match "media/pdf/*" $ do
        route   idRoute
        compile copyFileCompiler

    match "css/*" $ do
        route   idRoute
        compile compressCssCompiler

    -- Pages
    match "pages/*" $ do
        route   $ gsubRoute "pages/" (const "") `composeRoutes` setExtension "html"
        compile $ scriptaCompiler
            >>= loadAndApplyTemplate "templates/default.html" defaultContext
            >>= relativizeUrls

    -- Posts
    match "posts/**" $ do
        route $ setExtension "html"
        compile $ scriptaCompiler
            >>= loadAndApplyTemplate "templates/post.html"    postCtx
            >>= loadAndApplyTemplate "templates/default.html" postCtx
            >>= relativizeUrls

    match "photography/**" $ do
            route $ setExtension "html"
            compile $ scriptaCompiler
                >>= loadAndApplyTemplate "templates/photography.html" defaultContext
                >>= relativizeUrls

    match "music/**" $ do
                route $ setExtension "html"
                compile $ scriptaCompiler
                    >>= loadAndApplyTemplate "templates/default.html" defaultContext
                    >>= relativizeUrls

    match "archive/**.txt" $ do
          route $ setExtension "html"
          compile $ txtCompiler
              >>= loadAndApplyTemplate "templates/note.html" noteCtx
              >>= loadAndApplyTemplate "templates/default.html" noteCtx
              >>= relativizeUrls

    match "archive/media/**" $ do
          route idRoute
          compile copyFileCompiler

    -- Notes index page
    create ["notes.html"] $ do
        route idRoute
        compile $ do
            notes <- loadAll "archive/**.txt"
            let notesCtx =
                    listField "notes" noteCtx (return notes) `mappend`
                    constField "title" "Notes"               `mappend`
                    defaultContext

            makeItem ""
                >>= loadAndApplyTemplate "templates/notes.html" notesCtx
                >>= loadAndApplyTemplate "templates/default.html" notesCtx
                >>= relativizeUrls

    -- Archive page
    create ["archive.html"] $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/**"
            let archiveCtx =
                    listField "posts" postCtx (return posts) `mappend`
                    constField "title" "Archives"            `mappend`
                    defaultContext

            makeItem ""
                >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
                >>= loadAndApplyTemplate "templates/default.html" archiveCtx
                >>= relativizeUrls

    -- Blog page (posts listing)
    create ["blog.html"] $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/**"
            let blogCtx =
                    listField "posts" postCtx (return posts) `mappend`
                    constField "title" "Blog"                `mappend`
                    defaultContext

            makeItem ""
                >>= loadAndApplyTemplate "templates/blog.html" blogCtx
                >>= loadAndApplyTemplate "templates/default.html" blogCtx
                >>= relativizeUrls

    -- Projects page
    match "projects.md" $ do
        route $ setExtension "html"
        compile $ scriptaCompiler
            >>= loadAndApplyTemplate "templates/default.html" defaultContext
            >>= relativizeUrls

    -- Index page (landing page) - supports Scripta markup
    match "index.md" $ do
        route $ setExtension "html"
        compile $ scriptaCompiler
            >>= loadAndApplyTemplate "templates/default.html" defaultContext
            >>= relativizeUrls

    -- Templates
    match "templates/*" $ compile templateBodyCompiler

postCtx :: Context String
postCtx =
    dateField "date" "%B %e, %Y" `mappend`
    defaultContext

noteCtx :: Context String
noteCtx =
    field "title" extractTitle `mappend`
    defaultContext
  where
    extractTitle item = do
        let path = toFilePath (itemIdentifier item)
            filename = takeBaseName path
            -- Strip Zettelkasten ID prefix (e.g., "202102180950 ")
            title = dropWhile (== ' ') $ dropWhile (/= ' ') filename
        return $ if null title then filename else title

    takeBaseName p = reverse $ drop 1 $ dropWhile (/= '.') $ reverse $
                     reverse $ takeWhile (/= '/') $ reverse p

txtCompiler :: Compiler (Item String)
txtCompiler = do
    body <- getResourceBody
    let readerOpts = defaultHakyllReaderOptions
            { readerExtensions = enableExtension Ext_tex_math_dollars $
                                 enableExtension Ext_tex_math_double_backslash $
                                 readerExtensions defaultHakyllReaderOptions
            }
        writerOpts = defaultHakyllWriterOptions
            { writerHTMLMathMethod = MathJax "" }
        result = runPure $ do
            doc <- readMarkdown readerOpts (T.pack $ itemBody body)
            writeHtml5String writerOpts doc
    case result of
        Left err -> fail $ show err
        Right html -> makeItem (T.unpack html)

-- | Compiler that preprocesses Scripta markup before Pandoc
scriptaCompiler :: Compiler (Item String)
scriptaCompiler = do
    body <- getResourceBody
    let processed = processScripta (itemBody body)
        result = runPure $ do
            doc <- readMarkdown defaultHakyllReaderOptions (T.pack processed)
            writeHtml5String defaultHakyllWriterOptions doc
    case result of
        Left err -> fail $ show err
        Right html -> makeItem (T.unpack html)

