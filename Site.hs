{-# LANGUAGE OverloadedStrings #-}

import Data.Monoid (mappend)
import qualified Data.Text as T
import qualified Data.Map as M
import Hakyll
import Text.Pandoc
import Text.Pandoc.Options
import Scripta (processScripta)
import System.Directory (listDirectory, doesDirectoryExist)
import System.FilePath ((</>), takeExtension, takeBaseName)
import Control.Monad (filterM, forM)
import Data.List (isPrefixOf, isInfixOf, find, dropWhileEnd, sortBy)
import Data.Char (isSpace)
import Data.Maybe (catMaybes, mapMaybe)

main :: IO ()
main = do
    -- Pre-scan archive files for #post and #diary tags
    postMap <- scanArchiveForPosts "archive"
    diaryMap <- scanArchiveForDiary "archive"
    let postFiles = M.keys postMap
        diaryFiles = M.keys diaryMap

    hakyll $ do
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

        match "prog/**" $ do
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

        -- Posts (from posts/ directory)
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

        -- Archive notes that are posts (contain #post tag)
        match (fromList postFiles) $ do
            route $ customRoute (archiveToPostRoute postMap)
            compile $ txtPostCompiler
                >>= loadAndApplyTemplate "templates/post.html" archivePostCtx
                >>= loadAndApplyTemplate "templates/default.html" archivePostCtx
                >>= relativizeUrls

        -- Diary entries (archive notes with #diary tag) - MUST come before archive match
        match (fromList diaryFiles) $ do
            route $ customRoute (archiveToDiaryRoute diaryMap)
            compile $ txtDiaryCompiler
                >>= loadAndApplyTemplate "templates/post.html" diaryEntryCtx
                >>= loadAndApplyTemplate "templates/default.html" diaryEntryCtx
                >>= relativizeUrls

        -- Archive notes that are NOT posts or diary entries
        match "archive/**.txt" $ do
            route $ setExtension "html"
            compile $ txtCompiler
                >>= loadAndApplyTemplate "templates/note.html" noteCtx
                >>= loadAndApplyTemplate "templates/default.html" noteCtx
                >>= relativizeUrls

        match "archive/media/**" $ do
            route idRoute
            compile copyFileCompiler

        -- Notes index page (obscured URL) - excludes diary entries
        create ["brz891/notes/index.html"] $ do
            route idRoute
            compile $ do
                allNotes <- loadAll "archive/**.txt"
                -- Filter out diary entries
                let notes = filter (\n -> itemIdentifier n `notElem` diaryFiles) allNotes
                    notesCtx =
                        listField "notes" noteCtx (return notes) `mappend`
                        constField "title" "Notes"               `mappend`
                        defaultContext

                makeItem ""
                    >>= loadAndApplyTemplate "templates/notes.html" notesCtx
                    >>= loadAndApplyTemplate "templates/default.html" notesCtx
                    >>= relativizeUrls

        -- Diary index page (obscured URL)
        create ["brz891/diary/index.html"] $ do
            route idRoute
            compile $ do
                entries <- loadAll (fromList diaryFiles)
                sortedEntries <- recentFirst' entries
                let diaryIndexCtx =
                        listField "posts" diaryEntryCtx (return sortedEntries) `mappend`
                        constField "title" "Diary"                             `mappend`
                        defaultContext

                makeItem ""
                    >>= loadAndApplyTemplate "templates/blog.html" diaryIndexCtx
                    >>= loadAndApplyTemplate "templates/default.html" diaryIndexCtx
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

        -- Blog page (posts listing) - includes both posts/** and archive posts
        create ["blog.html"] $ do
            route idRoute
            compile $ do
                regularPosts <- loadAll "posts/**"
                archivePosts <- loadAll (fromList postFiles)
                let allPosts = regularPosts ++ archivePosts
                sortedPosts <- recentFirst' allPosts
                let blogCtx =
                        listField "posts" combinedPostCtx (return sortedPosts) `mappend`
                        constField "title" "Blog"                              `mappend`
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

-- | Combined context that works for both regular posts and archive posts
combinedPostCtx :: Context String
combinedPostCtx =
    field "date" getDate `mappend`
    field "title" getTitle `mappend`
    defaultContext
  where
    getDate item = do
        let path = toFilePath (itemIdentifier item)
            filename = reverse $ takeWhile (/= '/') $ reverse path
            basename = reverse $ drop 1 $ dropWhile (/= '.') $ reverse filename
        -- Check if it's an archive file (starts with 12 digits)
        if length filename >= 12 && all (`elem` ['0'..'9']) (take 12 filename)
            then do
                let zettelId = take 8 filename
                return $ formatDate zettelId
            -- Check if filename starts with YYYY-MM-DD format
            else if length basename > 10 && basename !! 4 == '-' && basename !! 7 == '-'
                then do
                    let year = take 4 basename
                        month = take 2 (drop 5 basename)
                        day = take 2 (drop 8 basename)
                    return $ formatDateParts year month day
                else do
                    -- Fall back to metadata date
                    metadata <- getMetadata (itemIdentifier item)
                    case lookupString "date" metadata of
                        Just d -> return d
                        Nothing -> return "Unknown date"

    getTitle item = do
        let path = toFilePath (itemIdentifier item)
            filename = reverse $ drop 1 $ dropWhile (/= '.') $ reverse $
                       reverse $ takeWhile (/= '/') $ reverse path
        -- Check if it's an archive file (Zettelkasten format with 12 digit prefix)
        if length filename >= 12 && all (`elem` ['0'..'9']) (take 12 filename)
            then do
                -- Read title from first line of file content
                content <- unsafeCompiler $ readFile path
                let contentLines = lines content
                    title = if not (null contentLines)
                            then head contentLines
                            else "Untitled"
                return $ if null title then "Untitled" else title
            else do
                metadata <- getMetadata (itemIdentifier item)
                case lookupString "title" metadata of
                    Just t -> return t
                    Nothing -> return filename

    formatDate zettelId =
        let year = take 4 zettelId
            month = take 2 (drop 4 zettelId)
            day = take 2 (drop 6 zettelId)
        in formatDateParts year month day

    formatDateParts year month day =
        let monthName = case month of
                "01" -> "January"; "02" -> "February"; "03" -> "March"
                "04" -> "April"; "05" -> "May"; "06" -> "June"
                "07" -> "July"; "08" -> "August"; "09" -> "September"
                "10" -> "October"; "11" -> "November"; "12" -> "December"
                _ -> month
            dayNum = dropWhile (== '0') day
        in monthName ++ " " ++ (if null dayNum then "0" else dayNum) ++ ", " ++ year

-- | Sort items by date, handling both regular posts and archive posts
recentFirst' :: [Item a] -> Compiler [Item a]
recentFirst' items = return $ sortBy (flip compareByDate) items
  where
    compareByDate a b = compare (getDateKey a) (getDateKey b)
    getDateKey item =
        let path = toFilePath (itemIdentifier item)
            filename = reverse $ takeWhile (/= '/') $ reverse path
        in if length filename >= 12 && all (`elem` ['0'..'9']) (take 12 filename)
           then take 12 filename  -- Zettelkasten ID is the date
           else filename          -- For regular posts, filename contains date

-- | Context for archive notes converted to posts
-- Extracts title from first line of content, date from filename
archivePostCtx :: Context String
archivePostCtx =
    field "date" extractDate `mappend`
    field "title" extractTitle `mappend`
    defaultContext
  where
    extractDate item = do
        let path = toFilePath (itemIdentifier item)
            filename = takeBaseName' path
            -- Extract YYYYMMDD from Zettelkasten ID
            zettelId = take 8 filename
            year = take 4 zettelId
            month = take 2 (drop 4 zettelId)
            day = take 2 (drop 6 zettelId)
            monthName = case month of
                "01" -> "January"; "02" -> "February"; "03" -> "March"
                "04" -> "April"; "05" -> "May"; "06" -> "June"
                "07" -> "July"; "08" -> "August"; "09" -> "September"
                "10" -> "October"; "11" -> "November"; "12" -> "December"
                _ -> month
            dayNum = dropWhile (== '0') day
        return $ monthName ++ " " ++ (if null dayNum then "0" else dayNum) ++ ", " ++ year

    extractTitle item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        let contentLines = lines content
            title = if not (null contentLines)
                    then head contentLines
                    else "Untitled"
        return $ if null title then "Untitled" else title

    takeBaseName' p = reverse $ drop 1 $ dropWhile (/= '.') $ reverse $
                      reverse $ takeWhile (/= '/') $ reverse p

-- | Context for diary entries
-- Extracts title from first line of content (e.g., "# 202601162353 My Title" -> "My Title")
-- Extracts date from Zettelkasten ID in filename
diaryEntryCtx :: Context String
diaryEntryCtx =
    field "date" extractDate `mappend`
    field "title" extractTitleFromContent `mappend`
    defaultContext
  where
    extractDate item = do
        let path = toFilePath (itemIdentifier item)
            filename = takeBaseName' path
            zettelId = take 8 filename
            year = take 4 zettelId
            month = take 2 (drop 4 zettelId)
            day = take 2 (drop 6 zettelId)
            monthName = case month of
                "01" -> "January"; "02" -> "February"; "03" -> "March"
                "04" -> "April"; "05" -> "May"; "06" -> "June"
                "07" -> "July"; "08" -> "August"; "09" -> "September"
                "10" -> "October"; "11" -> "November"; "12" -> "December"
                _ -> month
            dayNum = dropWhile (== '0') day
        return $ monthName ++ " " ++ (if null dayNum then "0" else dayNum) ++ ", " ++ year

    extractTitleFromContent item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        let contentLines = lines content
            -- Title is on line 1
            title = if not (null contentLines)
                    then head contentLines
                    else "Untitled"
        return $ if null title then "Untitled" else title

    takeBaseName' p = reverse $ drop 1 $ dropWhile (/= '.') $ reverse $
                      reverse $ takeWhile (/= '/') $ reverse p

noteCtx :: Context String
noteCtx =
    field "title" extractTitle `mappend`
    defaultContext
  where
    extractTitle item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        let contentLines = lines content
            title = if not (null contentLines)
                    then head contentLines
                    else "Untitled"
        return $ if null title then "Untitled" else title

txtCompiler :: Compiler (Item String)
txtCompiler = do
    body <- getResourceBody
    let content = stripFirstLine (itemBody body)
        readerOpts = defaultHakyllReaderOptions
            { readerExtensions = enableExtension Ext_tex_math_dollars $
                                 enableExtension Ext_tex_math_double_backslash $
                                 readerExtensions defaultHakyllReaderOptions
            }
        writerOpts = defaultHakyllWriterOptions
            { writerHTMLMathMethod = MathJax "" }
        result = runPure $ do
            doc <- readMarkdown readerOpts (T.pack content)
            writeHtml5String writerOpts doc
    case result of
        Left err -> fail $ show err
        Right html -> makeItem (T.unpack html)

-- | Strip the first line (title) from content
stripFirstLine :: String -> String
stripFirstLine = unlines . drop 1 . lines

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

-- | Compiler for archive posts - strips first line (title) and #post tags
txtPostCompiler :: Compiler (Item String)
txtPostCompiler = do
    body <- getResourceBody
    let content = stripPostTags $ stripFirstLine (itemBody body)
        readerOpts = defaultHakyllReaderOptions
            { readerExtensions = enableExtension Ext_tex_math_dollars $
                                 enableExtension Ext_tex_math_double_backslash $
                                 readerExtensions defaultHakyllReaderOptions
            }
        writerOpts = defaultHakyllWriterOptions
            { writerHTMLMathMethod = MathJax "" }
        result = runPure $ do
            doc <- readMarkdown readerOpts (T.pack content)
            writeHtml5String writerOpts doc
    case result of
        Left err -> fail $ show err
        Right html -> makeItem (T.unpack html)

-- | Strip #post and #post/category tags from content
stripPostTags :: String -> String
stripPostTags = unlines . filter (not . isPostTag) . lines
  where
    isPostTag line = "#post" `isPrefixOf` (dropWhile isSpace line)

-- | Scan archive directory for files containing #post tags
-- Returns a map of Identifier -> (Maybe category, title)
scanArchiveForPosts :: FilePath -> IO (M.Map Identifier (Maybe String, String))
scanArchiveForPosts dir = do
    files <- findTxtFiles dir
    results <- forM files $ \path -> do
        content <- readFile path
        let category = extractPostCategory content
            contentLines = lines content
            title = if not (null contentLines) then head contentLines else ""
        return $ if hasPostTag content
                 then Just (fromFilePath path, (category, title))
                 else Nothing
    return $ M.fromList $ catMaybes results

-- | Find all .txt files recursively in a directory
findTxtFiles :: FilePath -> IO [FilePath]
findTxtFiles dir = do
    entries <- listDirectory dir
    let paths = map (dir </>) entries
    files <- filterM (\p -> do
        isDir <- doesDirectoryExist p
        return $ not isDir && takeExtension p == ".txt") paths
    subdirs <- filterM doesDirectoryExist paths
    subfiles <- concat <$> mapM findTxtFiles subdirs
    return $ files ++ subfiles

-- | Check if content has a #post tag
hasPostTag :: String -> Bool
hasPostTag content = any isPostLine (lines content)
  where
    isPostLine line = "#post" `isPrefixOf` (dropWhile isSpace line)

-- | Extract category from #post/category tag (e.g., #post/physics -> Just "physics")
extractPostCategory :: String -> Maybe String
extractPostCategory content =
    case find isPostLine (lines content) of
        Just line ->
            let tag = dropWhile isSpace line
            in if "/" `isInfixOf` tag
               then Just $ takeWhile (/= '\n') $ drop 1 $ dropWhile (/= '/') tag
               else Nothing
        Nothing -> Nothing
  where
    isPostLine line = "#post" `isPrefixOf` (dropWhile isSpace line)

-- | Convert archive path to post path based on category and title
-- archive/202601162353 First Post.txt -> posts/first-post.html
-- archive/202601162353 Physics Note.txt (with #post/physics) -> posts/physics/physics-note.html
archiveToPostRoute :: M.Map Identifier (Maybe String, String) -> Identifier -> FilePath
archiveToPostRoute postMap ident =
    let (category, title) = M.findWithDefault (Nothing, "untitled") ident postMap
        slug = toSlug (if null title then "untitled" else title)
    in case category of
        Just cat -> "posts" </> cat </> slug ++ ".html"
        Nothing  -> "posts" </> slug ++ ".html"

-- | Convert title to URL-friendly slug
toSlug :: String -> String
toSlug = map toLower . map dashify . filter isValidChar
  where
    isValidChar c = c `elem` (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ " -")
    dashify ' ' = '-'
    dashify c = c
    toLower c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- | Scan archive directory for files containing #diary tag
-- Returns a map of Identifier -> title (from first line of file)
scanArchiveForDiary :: FilePath -> IO (M.Map Identifier String)
scanArchiveForDiary dir = do
    files <- findTxtFiles dir
    results <- forM files $ \path -> do
        content <- readFile path
        let contentLines = lines content
            title = if not (null contentLines) then head contentLines else ""
        return $ if hasTag "#diary" content
                 then Just (fromFilePath path, title)
                 else Nothing
    return $ M.fromList $ catMaybes results

-- | Check if content has a specific tag
hasTag :: String -> String -> Bool
hasTag tag content = any isTagLine (lines content)
  where
    isTagLine line = tag `isPrefixOf` (dropWhile isSpace line)

-- | Convert archive path to diary path using title-based slug
-- archive/202601162353.txt -> brz891/diary/us-situation-fubar.html
archiveToDiaryRoute :: M.Map Identifier String -> Identifier -> FilePath
archiveToDiaryRoute diaryMap ident =
    let title = M.findWithDefault "untitled" ident diaryMap
        slug = toSlug title
    in "brz891" </> "diary" </> slug ++ ".html"

-- | Compiler for diary entries - strips first line (title) and #diary tags
txtDiaryCompiler :: Compiler (Item String)
txtDiaryCompiler = do
    body <- getResourceBody
    let content = stripDiaryContent (itemBody body)
        readerOpts = defaultHakyllReaderOptions
            { readerExtensions = enableExtension Ext_tex_math_dollars $
                                 enableExtension Ext_tex_math_double_backslash $
                                 readerExtensions defaultHakyllReaderOptions
            }
        writerOpts = defaultHakyllWriterOptions
            { writerHTMLMathMethod = MathJax "" }
        result = runPure $ do
            doc <- readMarkdown readerOpts (T.pack content)
            writeHtml5String writerOpts doc
    case result of
        Left err -> fail $ show err
        Right html -> makeItem (T.unpack html)

-- | Strip first line (title) and #diary tags from content
stripDiaryContent :: String -> String
stripDiaryContent s =
    let ls = lines s
        -- Drop the first line (title)
        withoutTitle = drop 1 ls
        -- Filter out #diary tags
        withoutTags = filter (not . isDiaryTag) withoutTitle
    in unlines withoutTags
  where
    isDiaryTag line = "#diary" `isPrefixOf` (dropWhile isSpace line)

