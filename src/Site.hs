{-# LANGUAGE OverloadedStrings #-}

import Data.Monoid (mappend)
import qualified Data.Text as T
import qualified Data.Map as M
import Hakyll
import Text.Pandoc
import Text.Pandoc.Options
import Scripta (processScripta, LinkMap)
import System.FilePath ((</>), takeBaseName, takeFileName, takeExtension, dropExtension, replaceExtension)
import Control.Monad (forM)
import Data.List (sortBy, sort)
import Data.Char (isSpace)
import Data.Maybe (catMaybes)

-- Import from local modules
import Utils
import Archive

-- | Generic route for archive entries: prefix/slug.html
archiveToRoute :: String -> M.Map Identifier String -> Identifier -> FilePath
archiveToRoute prefix titleMap ident =
    let title = M.findWithDefault "untitled" ident titleMap
        slug = toSlug title
    in prefix </> slug ++ ".html"

main :: IO ()
main = do
    -- Pre-scan archive files for #post, #diary, #memoirs, #draft, #reading, and #note tags
    postMap <- scanArchiveForPosts "archive"
    diaryMap <- scanArchiveForTag "#diary" "archive"
    memoirsMap <- scanArchiveForTag "#memoirs" "archive"
    draftsMap <- scanArchiveForTag "#draft" "archive"
    readingMap <- scanArchiveForTag "#reading" "archive"
    notesMap <- scanArchiveForTag "#note" "archive"
    let postFiles = M.keys postMap
        diaryFiles = M.keys diaryMap
        memoirsFiles = M.keys memoirsMap
        draftsFiles = M.keys draftsMap
        readingFiles = M.keys readingMap
        noteFiles = M.keys notesMap

    -- Scan posts for content tags (#tag:xyz)
    postTagMap <- scanArchiveForContentTags "archive" postFiles
    let tagIndex = buildTagIndex postTagMap
        allTags = sort $ M.keys tagIndex

    -- Scan notes for content tags (#tag:xyz)
    noteTagMap <- scanArchiveForContentTags "archive" noteFiles
    let noteTagIndex = buildTagIndex noteTagMap
        allNoteTags = sort $ M.keys noteTagIndex

    -- Scan drafts for content tags (#tag:xyz)
    draftsTagMap <- scanArchiveForContentTags "archive" draftsFiles
    let draftsTagIndex = buildTagIndex draftsTagMap
        allDraftsTags = sort $ M.keys draftsTagIndex

    -- Build the link map for internal links
    linkMap <- buildLinkMap "archive" postMap diaryMap memoirsMap draftsMap readingMap

    -- Build navigation map for posts (prev/next links)
    regularPostFiles <- findMdFiles "content/posts"
    let allPostIdents = regularPostFiles ++ postFiles
    postNavMap <- buildPostNavMap postMap allPostIdents

    -- Build navigation map for notes (all archive files not matched by other rules)
    allArchiveFiles <- findTxtFiles "archive"
    let archiveNoteFiles = filter (`notElem` (postFiles ++ diaryFiles ++ memoirsFiles ++ draftsFiles ++ readingFiles)) (map fromFilePath allArchiveFiles)
    noteNavMap <- buildNoteNavMap archiveNoteFiles

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

        match "js/*" $ do
            route   idRoute
            compile copyFileCompiler

        -- Pages
        match "content/pages/*" $ do
            route   $ gsubRoute "content/pages/" (const "") `composeRoutes` setExtension "html"
            compile $ scriptaCompiler linkMap
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls

        -- Posts (from content/posts/ directory)
        match "content/posts/**" $ do
            route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
            compile $ scriptaCompiler linkMap
                >>= loadAndApplyTemplate "templates/post.html"    (postCtxWithNav postNavMap)
                >>= loadAndApplyTemplate "templates/default.html" (postCtxWithNav postNavMap)
                >>= relativizeUrls

        match "content/photography/**" $ do
            route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
            compile $ scriptaCompiler linkMap
                >>= loadAndApplyTemplate "templates/photography.html" defaultContext
                >>= relativizeUrls

        match "content/music/**" $ do
            route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
            compile $ scriptaCompiler linkMap
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls

        match "content/art/**" $ do
            route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
            compile $ scriptaCompiler linkMap
                >>= loadAndApplyTemplate "templates/art.html" defaultContext
                >>= relativizeUrls

        -- Archive notes that are posts (contain #post tag)
        match (fromList postFiles) $ do
            route $ customRoute (archiveToPostRoute postMap)
            compile $ txtPostCompiler linkMap
                >>= loadAndApplyTemplate "templates/post.html" (archivePostCtxWithNav postNavMap)
                >>= loadAndApplyTemplate "templates/default.html" (archivePostCtxWithNav postNavMap)
                >>= relativizeUrls

        -- Diary entries (archive notes with #diary tag) - MUST come before archive match
        match (fromList diaryFiles) $ do
            route $ customRoute (archiveToDiaryRoute diaryMap)
            compile $ txtDiaryCompiler linkMap
                >>= loadAndApplyTemplate "templates/post.html" diaryEntryCtx
                >>= loadAndApplyTemplate "templates/default.html" diaryEntryCtx
                >>= relativizeUrls

        -- Memoirs entries (archive notes with #memoirs tag) - MUST come before archive match
        match (fromList memoirsFiles) $ do
            route $ customRoute (archiveToMemoirsRoute memoirsMap)
            compile $ txtMemoirsCompiler linkMap
                >>= loadAndApplyTemplate "templates/post.html" memoirsEntryCtx
                >>= loadAndApplyTemplate "templates/default.html" memoirsEntryCtx
                >>= relativizeUrls

        -- Drafts entries (archive notes with #draft tag) - MUST come before archive match
        match (fromList draftsFiles) $ do
            route $ customRoute (archiveToDraftsRoute draftsMap)
            compile $ txtDraftsCompiler linkMap
                >>= loadAndApplyTemplate "templates/post.html" draftsEntryCtx
                >>= loadAndApplyTemplate "templates/default.html" draftsEntryCtx
                >>= relativizeUrls

        -- Reading entries (archive notes with #reading tag) - MUST come before archive match
        match (fromList readingFiles) $ do
            route $ customRoute (archiveToReadingRoute readingMap)
            compile $ txtReadingCompiler linkMap
                >>= loadAndApplyTemplate "templates/post.html" readingEntryCtx
                >>= loadAndApplyTemplate "templates/default.html" readingEntryCtx
                >>= relativizeUrls

        -- Archive notes that are NOT posts, diary, memoirs, drafts, or reading
        match "archive/**.txt" $ do
            route $ customRoute $ \ident ->
                let filename = takeBaseName (takeFileName (toFilePath ident))
                in "archive" </> toSlug filename ++ ".html"
            compile $ txtCompiler linkMap
                >>= loadAndApplyTemplate "templates/note.html" (noteCtxWithNav noteNavMap)
                >>= loadAndApplyTemplate "templates/default.html" (noteCtxWithNav noteNavMap)
                >>= relativizeUrls

        match "archive/media/**" $ do
            route idRoute
            compile copyFileCompiler

        -- Notes index page - only shows files with #note tag
        create ["notes/index.html"] $ do
            route idRoute
            compile $ do
                notes <- loadAll (fromList noteFiles)
                -- Create tag list items for buttons
                noteTagItems <- mapM makeItem allNoteTags
                let tagCtx = field "tag" (return . itemBody)
                    noteCtxWithTags = noteCtxWithTagsF noteTagMap
                    notesCtx =
                        listField "notes" noteCtxWithTags (return notes) `mappend`
                        listField "tagList" tagCtx (return noteTagItems) `mappend`
                        constField "title" "Notes"                       `mappend`
                        defaultContext

                makeItem ""
                    >>= loadAndApplyTemplate "templates/notes.html" notesCtx
                    >>= loadAndApplyTemplate "templates/default.html" notesCtx
                    >>= relativizeUrls

        -- Diary index page
        create ["diary/index.html"] $ do
            route idRoute
            compile $ do
                entries <- loadAll (fromList diaryFiles)
                sortedEntries <- recentFirst' entries
                let emptyTagCtx = field "tag" (return . itemBody)
                    diaryIndexCtx =
                        listField "posts" diaryEntryCtx (return sortedEntries) `mappend`
                        listField "tagList" emptyTagCtx (return [])            `mappend`
                        constField "title" "Diary"                             `mappend`
                        defaultContext

                makeItem ""
                    >>= loadAndApplyTemplate "templates/blog.html" diaryIndexCtx
                    >>= loadAndApplyTemplate "templates/default.html" diaryIndexCtx
                    >>= relativizeUrls

        -- Memoirs index page
        create ["memoirs/index.html"] $ do
            route idRoute
            compile $ do
                entries <- loadAll (fromList memoirsFiles)
                sortedEntries <- recentFirst' entries
                let emptyTagCtx = field "tag" (return . itemBody)
                    memoirsIndexCtx =
                        listField "posts" memoirsEntryCtx (return sortedEntries) `mappend`
                        listField "tagList" emptyTagCtx (return [])              `mappend`
                        constField "title" "Memoirs"                             `mappend`
                        defaultContext

                makeItem ""
                    >>= loadAndApplyTemplate "templates/blog.html" memoirsIndexCtx
                    >>= loadAndApplyTemplate "templates/default.html" memoirsIndexCtx
                    >>= relativizeUrls

        -- Auth check file for protected sections (used by JS to detect authentication)
        create ["memoirs/.auth-check"] $ do
            route idRoute
            compile $ makeItem ("ok" :: String)

        -- Drafts index page
        create ["drafts/index.html"] $ do
            route idRoute
            compile $ do
                entries <- loadAll (fromList draftsFiles)
                sortedEntries <- recentFirst' entries
                -- Create tag list items for buttons
                draftsTagItems <- mapM makeItem allDraftsTags
                let tagCtx = field "tag" (return . itemBody)
                    draftsCtxWithTags = draftsCtxWithTagsF draftsTagMap
                    draftsIndexCtx =
                        listField "posts" draftsCtxWithTags (return sortedEntries) `mappend`
                        listField "tagList" tagCtx (return draftsTagItems)         `mappend`
                        constField "title" "Drafts"                                `mappend`
                        defaultContext

                makeItem ""
                    >>= loadAndApplyTemplate "templates/blog.html" draftsIndexCtx
                    >>= loadAndApplyTemplate "templates/default.html" draftsIndexCtx
                    >>= relativizeUrls

        -- Reading index page
        create ["reading/index.html"] $ do
            route idRoute
            compile $ do
                entries <- loadAll (fromList readingFiles)
                sortedEntries <- recentFirst' entries
                let emptyTagCtx = field "tag" (return . itemBody)
                    readingIndexCtx =
                        listField "posts" readingEntryCtx (return sortedEntries) `mappend`
                        listField "tagList" emptyTagCtx (return [])              `mappend`
                        constField "title" "Reading"                             `mappend`
                        defaultContext

                makeItem ""
                    >>= loadAndApplyTemplate "templates/blog.html" readingIndexCtx
                    >>= loadAndApplyTemplate "templates/default.html" readingIndexCtx
                    >>= relativizeUrls

        -- Archive page
        create ["archive.html"] $ do
            route idRoute
            compile $ do
                posts <- recentFirst =<< loadAll "content/posts/**"
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
                regularPosts <- loadAll "content/posts/**"
                archivePosts <- loadAll (fromList postFiles)
                let allPosts = regularPosts ++ archivePosts
                sortedPosts <- recentFirst' allPosts
                -- Create tag list items for buttons
                tagItems <- mapM makeItem allTags
                let tagCtx = field "tag" (return . itemBody)
                    postCtxWithTags = combinedPostCtxWithTags postTagMap
                    blogCtx =
                        listField "posts" postCtxWithTags (return sortedPosts) `mappend`
                        listField "tagList" tagCtx (return tagItems)           `mappend`
                        constField "title" "Blog"                              `mappend`
                        defaultContext

                makeItem ""
                    >>= loadAndApplyTemplate "templates/blog.html" blogCtx
                    >>= loadAndApplyTemplate "templates/default.html" blogCtx
                    >>= relativizeUrls

        -- Projects page
        match "content/projects.md" $ do
            route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
            compile $ scriptaCompiler linkMap
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls

        -- Index page (landing page) - supports Scripta markup
        match "content/index.md" $ do
            route $ gsubRoute "content/" (const "") `composeRoutes` setExtension "html"
            compile $ scriptaCompiler linkMap
                >>= loadAndApplyTemplate "templates/default.html" defaultContext
                >>= relativizeUrls

        -- Templates
        match "templates/*" $ compile templateBodyCompiler

postCtx :: Context String
postCtx = postCtxWithNav M.empty

-- | Post context with navigation (prev/next links)
postCtxWithNav :: NavMap -> Context String
postCtxWithNav navMap =
    navField "prevUrl" fst navMap `mappend`
    navField "nextUrl" snd navMap `mappend`
    dateField "date" "%B %e, %Y" `mappend`
    field "wordcount" wordCount `mappend`
    defaultContext
  where
    wordCount item = return $ show $ length $ words $ stripHtmlTags $ itemBody item
    navField name selector nm = field name $ \item ->
        case M.lookup (itemIdentifier item) nm of
            Just pair -> case selector pair of
                Just url -> return url
                Nothing -> fail $ "No " ++ name
            Nothing -> fail $ "No " ++ name

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
                -- Read title from first line of file content (after preprocessing)
                content <- unsafeCompiler $ readFile path
                let preprocessed = preprocessScriptaImport content
                    title = extractFirstLineTitle preprocessed
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

-- | Combined context with tags field for blog page filtering
combinedPostCtxWithTags :: M.Map Identifier [String] -> Context String
combinedPostCtxWithTags tagMap =
    field "tags" getTags `mappend`
    field "content" getContent `mappend`
    field "mtime" getMtime `mappend`
    combinedPostCtx
  where
    getTags item = return $ unwords $ M.findWithDefault [] (itemIdentifier item) tagMap
    getContent item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        return $ escapeHtmlAttr content
    getMtime item = do
        let path = toFilePath (itemIdentifier item)
        mtime <- unsafeCompiler $ getModTime path
        return mtime

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
archivePostCtx = archivePostCtxWithNav M.empty

-- | Archive post context with navigation
archivePostCtxWithNav :: NavMap -> Context String
archivePostCtxWithNav navMap =
    navField "prevUrl" fst navMap `mappend`
    navField "nextUrl" snd navMap `mappend`
    field "date" extractDate `mappend`
    field "title" extractTitle `mappend`
    field "wordcount" wordCount `mappend`
    defaultContext
  where
    wordCount item = return $ show $ length $ words $ stripHtmlTags $ itemBody item
    extractDate item = return $ formatZettelDate $ takeBaseName' $ toFilePath (itemIdentifier item)
    extractTitle item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        return $ extractFirstLineTitle $ preprocessScriptaImport content
    navField name selector nm = field name $ \item ->
        case M.lookup (itemIdentifier item) nm of
            Just pair -> case selector pair of
                Just url -> return url
                Nothing -> fail $ "No " ++ name
            Nothing -> fail $ "No " ++ name

-- | Context for archive entries (diary, memoirs, etc.)
-- Extracts title from first line of content, date from Zettelkasten ID in filename
archiveEntryCtx :: Context String
archiveEntryCtx =
    field "date" extractDate `mappend`
    field "title" extractTitle `mappend`
    field "wordcount" wordCount `mappend`
    field "content" getContent `mappend`
    field "mtime" getMtime `mappend`
    constField "tags" ""       `mappend`
    defaultContext
  where
    wordCount item = return $ show $ length $ words $ stripHtmlTags $ itemBody item
    getContent item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        return $ escapeHtmlAttr content
    getMtime item = do
        let path = toFilePath (itemIdentifier item)
        mtime <- unsafeCompiler $ getModTime path
        return mtime
    extractDate item = return $ formatZettelDate $ takeBaseName' $ toFilePath (itemIdentifier item)
    extractTitle item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        return $ extractFirstLineTitle $ preprocessScriptaImport content

-- | Aliases for backward compatibility
diaryEntryCtx :: Context String
diaryEntryCtx = archiveEntryCtx

memoirsEntryCtx :: Context String
memoirsEntryCtx = archiveEntryCtx

draftsEntryCtx :: Context String
draftsEntryCtx = archiveEntryCtx

readingEntryCtx :: Context String
readingEntryCtx = archiveEntryCtx

noteCtx :: Context String
noteCtx = noteCtxWithNav M.empty

-- | Note context with navigation
noteCtxWithNav :: NavMap -> Context String
noteCtxWithNav navMap =
    navField "prevUrl" fst navMap `mappend`
    navField "nextUrl" snd navMap `mappend`
    field "title" extractTitle `mappend`
    defaultContext
  where
    extractTitle item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        return $ extractFirstLineTitle $ preprocessScriptaImport content
    navField name selector nm = field name $ \item ->
        case M.lookup (itemIdentifier item) nm of
            Just pair -> case selector pair of
                Just url -> return url
                Nothing -> fail $ "No " ++ name
            Nothing -> fail $ "No " ++ name

-- | Note context with tags field for notes page filtering
noteCtxWithTagsF :: M.Map Identifier [String] -> Context String
noteCtxWithTagsF tagMap =
    field "tags" getTags `mappend`
    field "content" getContent `mappend`
    field "mtime" getMtime `mappend`
    noteCtx
  where
    getTags item = return $ unwords $ M.findWithDefault [] (itemIdentifier item) tagMap
    getContent item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        return $ escapeHtmlAttr content
    getMtime item = do
        let path = toFilePath (itemIdentifier item)
        mtime <- unsafeCompiler $ getModTime path
        return mtime

-- | Drafts context with tags field for drafts page filtering
draftsCtxWithTagsF :: M.Map Identifier [String] -> Context String
draftsCtxWithTagsF tagMap =
    field "tags" getTags `mappend`
    field "content" getContent `mappend`
    field "mtime" getMtime `mappend`
    draftsEntryCtx
  where
    getTags item = return $ unwords $ M.findWithDefault [] (itemIdentifier item) tagMap
    getContent item = do
        let path = toFilePath (itemIdentifier item)
        content <- unsafeCompiler $ readFile path
        return $ escapeHtmlAttr content
    getMtime item = do
        let path = toFilePath (itemIdentifier item)
        mtime <- unsafeCompiler $ getModTime path
        return mtime

txtCompiler :: LinkMap -> Compiler (Item String)
txtCompiler linkMap = do
    body <- getResourceBody
    let content = processScripta linkMap $ stripFirstLineTags $ stripFirstLine $ preprocessScriptaImport (itemBody body)
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

-- | Compiler that preprocesses Scripta markup before Pandoc
scriptaCompiler :: LinkMap -> Compiler (Item String)
scriptaCompiler linkMap = do
    body <- getResourceBody
    let processed = processScripta linkMap (itemBody body)
        result = runPure $ do
            doc <- readMarkdown defaultHakyllReaderOptions (T.pack processed)
            writeHtml5String defaultHakyllWriterOptions doc
    case result of
        Left err -> fail $ show err
        Right html -> makeItem (T.unpack html)

-- | Compiler for archive posts - strips first line (title) and tags from first content line
txtPostCompiler :: LinkMap -> Compiler (Item String)
txtPostCompiler linkMap = do
    body <- getResourceBody
    let content = processScripta linkMap $ stripFirstLineTags $ stripFirstLine $ preprocessScriptaImport (itemBody body)
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

-- | Aliases using generic archiveToRoute
archiveToDiaryRoute :: M.Map Identifier String -> Identifier -> FilePath
archiveToDiaryRoute = archiveToRoute "diary"

archiveToMemoirsRoute :: M.Map Identifier String -> Identifier -> FilePath
archiveToMemoirsRoute = archiveToRoute "memoirs"

archiveToDraftsRoute :: M.Map Identifier String -> Identifier -> FilePath
archiveToDraftsRoute = archiveToRoute "drafts"

archiveToReadingRoute :: M.Map Identifier String -> Identifier -> FilePath
archiveToReadingRoute = archiveToRoute "reading"

-- | Build a map from Zettelkasten ID to (URL, Title) for internal links
buildLinkMap :: FilePath
             -> M.Map Identifier (Maybe String, String)  -- postMap
             -> M.Map Identifier String                   -- diaryMap
             -> M.Map Identifier String                   -- memoirsMap
             -> M.Map Identifier String                   -- draftsMap
             -> M.Map Identifier String                   -- readingMap
             -> IO LinkMap
buildLinkMap dir postMap diaryMap memoirsMap draftsMap readingMap = do
    files <- findTxtFiles dir
    results <- forM files $ \path -> do
        content <- readFile path
        let preprocessed = preprocessScriptaImport content
            ident = fromFilePath path
            filename = takeBaseName path
            zettelId = take 12 filename  -- Get the Zettelkasten ID
            title = extractFirstLineTitle preprocessed

            -- Determine URL based on which map the file is in
            url = if ident `M.member` postMap
                  then "/" ++ archiveToPostRoute postMap ident
                  else if ident `M.member` diaryMap
                       then "/" ++ archiveToDiaryRoute diaryMap ident
                       else if ident `M.member` memoirsMap
                            then "/" ++ archiveToMemoirsRoute memoirsMap ident
                       else if ident `M.member` draftsMap
                            then "/" ++ archiveToDraftsRoute draftsMap ident
                       else if ident `M.member` readingMap
                            then "/" ++ archiveToReadingRoute readingMap ident
                            else "/archive/" ++ toSlug filename ++ ".html"

        -- Only include files with valid Zettelkasten IDs (12 digits)
        return $ if length filename >= 12 && all (`elem` ['0'..'9']) (take 12 filename)
                 then Just (zettelId, (url, title))
                 else Nothing

    return $ M.fromList $ catMaybes results

-- | Generic compiler for tagged archive entries - strips first line and specified tag
txtTagCompiler :: String -> LinkMap -> Compiler (Item String)
txtTagCompiler tag linkMap = do
    body <- getResourceBody
    let content = processScripta linkMap $ stripTagContent tag $ preprocessScriptaImport (itemBody body)
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

-- | Strip first line (title) and tags from first content line
stripTagContent :: String -> String -> String
stripTagContent _ s = stripFirstLineTags $ stripFirstLine s

-- | Aliases for backward compatibility
txtDiaryCompiler :: LinkMap -> Compiler (Item String)
txtDiaryCompiler = txtTagCompiler "#diary"

txtMemoirsCompiler :: LinkMap -> Compiler (Item String)
txtMemoirsCompiler = txtTagCompiler "#memoirs"

txtDraftsCompiler :: LinkMap -> Compiler (Item String)
txtDraftsCompiler = txtTagCompiler "#draft"

txtReadingCompiler :: LinkMap -> Compiler (Item String)
txtReadingCompiler = txtTagCompiler "#reading"

-- | Type alias for navigation map: Identifier -> (Maybe prevUrl, Maybe nextUrl)
type NavMap = M.Map Identifier (Maybe String, Maybe String)

-- | Build navigation map for posts
-- Posts are sorted by date (newest first), navigation goes chronologically
buildPostNavMap :: M.Map Identifier (Maybe String, String) -> [Identifier] -> IO NavMap
buildPostNavMap archivePostMap allIdents = do
    -- Get dates and routes for all posts
    postsWithInfo <- forM allIdents $ \ident -> do
        let path = toFilePath ident
            filename = takeFileName path
            basename = dropExtension filename
        -- Determine date key and route
        if takeExtension path == ".txt"
            then do
                -- Archive post - date is first 8 digits of filename
                let dateKey = take 8 filename
                    route = "/" ++ archiveToPostRoute archivePostMap ident
                return (ident, dateKey, route)
            else do
                -- Regular post - date is YYYY-MM-DD prefix
                let dateKey = take 10 basename
                    route = "/" ++ replaceExtension path "html"
                return (ident, dateKey, route)
    -- Sort by date (newest first)
    let sorted = sortBy (\(_,d1,_) (_,d2,_) -> compare d2 d1) postsWithInfo
        identRoutes = [(i, r) | (i, _, r) <- sorted]
    -- Build prev/next map
    return $ buildNavFromList identRoutes

-- | Build navigation map from sorted list of (Identifier, route)
-- Navigation is circular: last wraps to first and vice versa
buildNavFromList :: [(Identifier, String)] -> NavMap
buildNavFromList [] = M.empty
buildNavFromList items = M.fromList $ zipWith3 mkEntry items prevs nexts
  where
    routes = map snd items
    -- Circular: prev of first is last, next of last is first
    prevs = map Just $ last routes : init routes
    nexts = map Just $ tail routes ++ [head routes]
    mkEntry (ident, _) prev next = (ident, (prev, next))

-- | Build navigation map for notes
buildNoteNavMap :: [Identifier] -> IO NavMap
buildNoteNavMap noteIdents = do
    let notesWithInfo = map (\ident ->
            let path = toFilePath ident
                filename = takeFileName path
                dateKey = take 12 filename  -- Zettelkasten ID for sorting
                route = "/archive/" ++ toSlug (takeBaseName filename) ++ ".html"
            in (ident, dateKey, route)) noteIdents
        -- Sort by date (newest first)
        sorted = sortBy (\(_,d1,_) (_,d2,_) -> compare d2 d1) notesWithInfo
        identRoutes = [(i, r) | (i, _, r) <- sorted]
    return $ buildNavFromList identRoutes

