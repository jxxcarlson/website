{-# LANGUAGE OverloadedStrings #-}

import Data.Monoid (mappend)
import qualified Data.Text as T
import Hakyll
import Text.Pandoc
import Text.Pandoc.Options

main :: IO ()
main = hakyll $ do
    -- Static files
    match "images/*" $ do
        route   idRoute
        compile copyFileCompiler

    match "css/*" $ do
        route   idRoute
        compile compressCssCompiler

    -- Pages
    match "pages/*" $ do
        route   $ gsubRoute "pages/" (const "") `composeRoutes` setExtension "html"
        compile $ pandocCompiler
            >>= loadAndApplyTemplate "templates/default.html" defaultContext
            >>= relativizeUrls

    -- Posts
    match "posts/**" $ do
        route $ setExtension "html"
        compile $ pandocCompiler
            >>= loadAndApplyTemplate "templates/post.html"    postCtx
            >>= loadAndApplyTemplate "templates/default.html" postCtx
            >>= relativizeUrls


    match "archive/**.txt" $ do
          route $ setExtension "html"
          compile $ txtCompiler
              >>= loadAndApplyTemplate "templates/note.html" defaultContext
              >>= loadAndApplyTemplate "templates/default.html" defaultContext
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

    -- Index page
    match "index.html" $ do
        route idRoute
        compile $ do
            posts <- recentFirst =<< loadAll "posts/**"
            let indexCtx =
                    listField "posts" postCtx (return posts) `mappend`
                    defaultContext

            getResourceBody
                >>= applyAsTemplate indexCtx
                >>= loadAndApplyTemplate "templates/default.html" indexCtx
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
    let result = runPure $ do
            doc <- readMarkdown defaultHakyllReaderOptions (T.pack $ itemBody body)
            writeHtml5String defaultHakyllWriterOptions doc
    case result of
        Left err -> fail $ show err
        Right html -> makeItem (T.unpack html)

