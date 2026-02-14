{-# LANGUAGE OverloadedStrings #-}

module Grab
    ( grabURL
    , GrabResult(..)
    , OutputFormat(..)
    ) where

import Text.HTML.TagSoup (parseTags, Tag(..), Attribute)
import Network.HTTP.Simple
    ( httpBS
    , getResponseBody
    , getResponseStatusCode
    , parseRequest
    , setRequestHeader
    )
import qualified Data.ByteString.Char8 as BS
import Data.Char (toLower, isAlphaNum, isSpace)
import Data.List (isInfixOf)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Control.Exception (try, SomeException)


-- | Output format for grabbed content
data OutputFormat = Markdown | Scripta deriving (Eq, Show)

-- | Result of grabbing a URL
data GrabResult = GrabResult
    { grabTitle    :: String
    , grabContent  :: String
    , grabFilename :: String
    } deriving (Show)

-- | Main entry point: fetch a URL and convert its content
grabURL :: String -> OutputFormat -> IO (Either String GrabResult)
grabURL url fmt = do
    result <- try (fetchURL url) :: IO (Either SomeException (Int, String))
    case result of
        Left err -> return $ Left $ "HTTP error: " ++ show err
        Right (status, body)
            | status >= 400 -> return $ Left $ "HTTP " ++ show status ++ " error"
            | otherwise -> do
                let tags = parseTags body
                    title = extractTitle tags
                    cleaned = cleanTags tags
                    mainContent = extractMainContent cleaned
                    noFirstH1 = stripFirstH1 mainContent
                    converted = convertTags fmt noFirstH1
                    fixed = fixupLinks fmt converted
                    document = "# " ++ title ++ "\n\n" ++ collapseBlankLines fixed
                filename <- generateFilename title fmt
                return $ Right $ GrabResult title document filename

-- | Fetch HTML from a URL, returning (status code, body)
fetchURL :: String -> IO (Int, String)
fetchURL url = do
    req0 <- parseRequest url
    let req = setRequestHeader "User-Agent"
                ["Mozilla/5.0 (compatible; GrabBot/1.0)"] req0
    response <- httpBS req
    let status = getResponseStatusCode response
        body = BS.unpack (getResponseBody response)
    return (status, body)

-- | Extract the page title from parsed tags.
--   Tries <title>, then <meta property="og:title">, then first <h1>.
extractTitle :: [Tag String] -> String
extractTitle tags =
    case findTitleTag tags of
        Just t  -> trim t
        Nothing ->
            case findOgTitle tags of
                Just t  -> trim t
                Nothing ->
                    case findFirstH1 tags of
                        Just t  -> trim t
                        Nothing -> "Untitled"

-- | Find content of <title> tag
findTitleTag :: [Tag String] -> Maybe String
findTitleTag [] = Nothing
findTitleTag (TagOpen name _ : rest)
    | map toLower name == "title" = Just (extractText (takeWhileTags rest))
findTitleTag (_ : rest) = findTitleTag rest

-- | Find og:title from <meta> tags
findOgTitle :: [Tag String] -> Maybe String
findOgTitle [] = Nothing
findOgTitle (TagOpen name attrs : _)
    | map toLower name == "meta"
    , lookupCI "property" attrs == Just "og:title"
    = lookupCI "content" attrs
findOgTitle (_ : rest) = findOgTitle rest

-- | Find text inside first <h1>
findFirstH1 :: [Tag String] -> Maybe String
findFirstH1 [] = Nothing
findFirstH1 (TagOpen name _ : rest)
    | map toLower name == "h1" = Just (extractText (takeWhileTags rest))
findFirstH1 (_ : rest) = findFirstH1 rest

-- | Take tags until the corresponding close tag at the same nesting level
takeWhileTags :: [Tag String] -> [Tag String]
takeWhileTags = go (0 :: Int)
  where
    go _ [] = []
    go 0 (TagClose _ : _) = []
    go n (t@(TagClose _) : rest) = t : go (n - 1) rest
    go n (t@(TagOpen _ _) : rest) = t : go (n + 1) rest
    go n (t : rest) = t : go n rest

-- | Extract plain text from a list of tags (concatenating TagText nodes)
extractText :: [Tag String] -> String
extractText = concatMap getText
  where
    getText (TagText s) = s
    getText _           = ""

-- | Case-insensitive attribute lookup.
--   TagSoup's Attribute String is (String, String).
lookupCI :: String -> [Attribute String] -> Maybe String
lookupCI key = lookup (map toLower key) . map (\(k, v) -> (map toLower k, v))

-- | Tags to strip entirely (including their content)
stripElements :: [String]
stripElements =
    [ "script", "style", "nav", "footer", "aside"
    , "iframe", "noscript", "svg", "form", "button"
    , "input", "header"
    ]

-- | Class/id substrings that indicate ad or non-content elements
adPatterns :: [String]
adPatterns =
    [ "advert", "ad-", "sidebar", "social-share", "share-bar"
    , "newsletter", "popup", "modal", "cookie", "banner"
    , "related-posts", "recommended"
    ]

-- | Check if an element has ad-related classes or IDs
isAdElement :: [Attribute String] -> Bool
isAdElement attrs =
    let classVal = map toLower $ maybe "" id $ lookupCI "class" attrs
        idVal    = map toLower $ maybe "" id $ lookupCI "id" attrs
    in any (`isInfixOf` classVal) adPatterns
       || any (`isInfixOf` idVal) adPatterns

-- | Remove unwanted tags and their content from the tag list
cleanTags :: [Tag String] -> [Tag String]
cleanTags = go
  where
    go [] = []
    go (TagOpen name attrs : rest)
        | map toLower name `elem` stripElements =
            go (dropUntilClose name rest)
        | isAdElement attrs =
            go (dropUntilClose name rest)
        | otherwise = TagOpen name attrs : go rest
    go (t : rest) = t : go rest

-- | Drop tags until the matching close tag (handling nesting)
dropUntilClose :: String -> [Tag String] -> [Tag String]
dropUntilClose target = go (1 :: Int)
  where
    go _ [] = []
    go n (TagOpen name _ : rest)
        | map toLower name == map toLower target = go (n + 1) rest
    go n (TagClose name : rest)
        | map toLower name == map toLower target =
            if n <= 1 then rest else go (n - 1) rest
    go n (_ : rest) = go n rest

-- | Extract main content area: <article>, <main>, or <body>
extractMainContent :: [Tag String] -> [Tag String]
extractMainContent tags =
    case findContentIn "article" tags of
        Just content -> content
        Nothing ->
            case findContentIn "main" tags of
                Just content -> content
                Nothing ->
                    case findContentIn "body" tags of
                        Just content -> content
                        Nothing      -> tags  -- Fall back to all tags

-- | Find the content between a given element's open and close tags
findContentIn :: String -> [Tag String] -> Maybe [Tag String]
findContentIn _ [] = Nothing
findContentIn target (TagOpen name _ : rest)
    | map toLower name == target = Just (takeUntilClose target rest)
findContentIn target (_ : rest) = findContentIn target rest

-- | Take tags until the matching close tag (handling nesting)
takeUntilClose :: String -> [Tag String] -> [Tag String]
takeUntilClose target = go (1 :: Int)
  where
    go _ [] = []
    go n (t@(TagOpen name _) : rest)
        | map toLower name == map toLower target = t : go (n + 1) rest
    go n (TagClose name : rest)
        | map toLower name == map toLower target =
            if n <= 1 then rest else TagClose name : go (n - 1) rest
    go n (t : rest) = t : go n rest

-- | Strip the first <h1> element from tags to avoid duplicate title
stripFirstH1 :: [Tag String] -> [Tag String]
stripFirstH1 [] = []
stripFirstH1 (TagOpen name _ : rest)
    | map toLower name == "h1" = dropUntilClose "h1" rest
stripFirstH1 (t : rest) = t : stripFirstH1 rest

-- | Convert a list of HTML tags to the target format.
--   Tracks whether we are inside a <pre> block to pass content through verbatim.
convertTags :: OutputFormat -> [Tag String] -> String
convertTags fmt = go False
  where
    go :: Bool -> [Tag String] -> String
    go _ [] = ""

    -- Opening tags
    go inPre (TagOpen name attrs : rest) =
        let lname = map toLower name
        in case lname of
            -- Pre / code blocks
            "pre" -> "\n```\n" ++ go True rest
            "code"
                | not inPre -> "`" ++ go inPre rest
                | otherwise -> go inPre rest

            -- Headings
            _ | lname `elem` ["h1","h2","h3","h4","h5","h6"] ->
                let level = read [last lname] :: Int
                    prefix = replicate level '#'
                in "\n" ++ prefix ++ " " ++ go inPre rest

            -- Images
            "img" ->
                let src = maybe "" id $ lookupCI "src" attrs
                    alt = maybe "" id $ lookupCI "alt" attrs
                in case fmt of
                    Markdown -> "![" ++ alt ++ "](" ++ src ++ ")" ++ go inPre rest
                    Scripta  -> "\n| image\n" ++ src ++ "\n" ++ go inPre rest

            -- Links
            "a" ->
                let href = maybe "" id $ lookupCI "href" attrs
                in case fmt of
                    Markdown -> "[{LINK_URL:" ++ href ++ "}" ++ go inPre rest
                    Scripta  -> "[link {LINK_URL:" ++ href ++ "}" ++ go inPre rest

            -- Bold
            _ | lname `elem` ["strong", "b"] ->
                case fmt of
                    Markdown -> "**" ++ go inPre rest
                    Scripta  -> "[b " ++ go inPre rest

            -- Italic
            _ | lname `elem` ["em", "i"] ->
                case fmt of
                    Markdown -> "*" ++ go inPre rest
                    Scripta  -> "[i " ++ go inPre rest

            -- Underline
            "u" ->
                case fmt of
                    Markdown -> "<u>" ++ go inPre rest
                    Scripta  -> "[u " ++ go inPre rest

            -- Block elements
            "p"          -> "\n\n" ++ go inPre rest
            "br"         -> "\n" ++ go inPre rest
            "hr"         -> "\n---\n" ++ go inPre rest
            "li"         -> "\n- " ++ go inPre rest
            "blockquote" -> "\n> " ++ go inPre rest

            -- Div / section / span: just pass through
            _ -> go inPre rest

    -- Closing tags
    go inPre (TagClose name : rest) =
        let lname = map toLower name
        in case lname of
            "pre" -> "\n```\n" ++ go False rest
            "code"
                | not inPre -> "`" ++ go inPre rest
                | otherwise -> go inPre rest

            -- Headings close: just add newline
            _ | lname `elem` ["h1","h2","h3","h4","h5","h6"] ->
                "\n" ++ go inPre rest

            -- Links close
            "a" -> "]" ++ go inPre rest

            -- Bold close
            _ | lname `elem` ["strong", "b"] ->
                case fmt of
                    Markdown -> "**" ++ go inPre rest
                    Scripta  -> "]" ++ go inPre rest

            -- Italic close
            _ | lname `elem` ["em", "i"] ->
                case fmt of
                    Markdown -> "*" ++ go inPre rest
                    Scripta  -> "]" ++ go inPre rest

            -- Underline close
            "u" ->
                case fmt of
                    Markdown -> "</u>" ++ go inPre rest
                    Scripta  -> "]" ++ go inPre rest

            -- Paragraph close
            "p" -> "\n\n" ++ go inPre rest

            -- Blockquote close
            "blockquote" -> "\n" ++ go inPre rest

            _ -> go inPre rest

    -- Text nodes
    go inPre (TagText s : rest)
        | inPre     = s ++ go inPre rest
        | otherwise = collapseSpaces s ++ go inPre rest

    -- Comments, etc.
    go inPre (_ : rest) = go inPre rest

-- | Collapse multiple spaces into single space in text nodes
collapseSpaces :: String -> String
collapseSpaces [] = []
collapseSpaces (c:cs)
    | isSpace c = ' ' : collapseSpaces (dropWhile isSpace cs)
    | otherwise = c : collapseSpaces cs

-- | Post-process link markers into proper link syntax.
--
--   Markdown: [{LINK_URL:url}text] -> [text](url)
--   Scripta:  [link {LINK_URL:url}text] -> [link text url]
fixupLinks :: OutputFormat -> String -> String
fixupLinks Markdown = fixupMarkdownLinks
fixupLinks Scripta  = fixupScriptaLinks

-- | Fix Markdown link markers: [{LINK_URL:url}text] -> [text](url)
fixupMarkdownLinks :: String -> String
fixupMarkdownLinks [] = []
fixupMarkdownLinks ('[':'{':'L':'I':'N':'K':'_':'U':'R':'L':':':rest) =
    let (url, afterUrl) = break (== '}') rest
        afterBrace = drop 1 afterUrl  -- skip '}'
        (text, afterClose) = break (== ']') afterBrace
        afterBracket = drop 1 afterClose  -- skip ']'
    in "[" ++ trim text ++ "](" ++ url ++ ")" ++ fixupMarkdownLinks afterBracket
fixupMarkdownLinks (c:cs) = c : fixupMarkdownLinks cs

-- | Fix Scripta link markers: [link {LINK_URL:url}text] -> [link text url]
fixupScriptaLinks :: String -> String
fixupScriptaLinks [] = []
fixupScriptaLinks ('[':'l':'i':'n':'k':' ':'{':'L':'I':'N':'K':'_':'U':'R':'L':':':rest) =
    let (url, afterUrl) = break (== '}') rest
        afterBrace = drop 1 afterUrl  -- skip '}'
        (text, afterClose) = break (== ']') afterBrace
        afterBracket = drop 1 afterClose  -- skip ']'
    in "[link " ++ trim text ++ " " ++ url ++ "]" ++ fixupScriptaLinks afterBracket
fixupScriptaLinks (c:cs) = c : fixupScriptaLinks cs

-- | Collapse 3+ consecutive blank lines to 2
collapseBlankLines :: String -> String
collapseBlankLines = unlines . go . lines
  where
    go [] = []
    go (a:b:c:rest)
        | all isSpaceOrEmpty [a, b, c] = go (a:b:rest)
    go (x:rest) = x : go rest
    isSpaceOrEmpty s = null s || all isSpace s

-- | Generate a filename with timestamp and slugified title
generateFilename :: String -> OutputFormat -> IO String
generateFilename title fmt = do
    now <- getCurrentTime
    let timestamp = formatTime defaultTimeLocale "%Y%m%d%H%M%S" now
        slug = slugify title
        ext = case fmt of
                Markdown -> ".md"
                Scripta  -> ".scripta"
    return $ "grab-" ++ timestamp ++ "-" ++ slug ++ ext

-- | Slugify a title: lowercase, spaces to dashes, alphanumeric + dash only, max 40 chars
slugify :: String -> String
slugify = take 40 . collapseHyphens . map dashify . filter isValidChar . map toLower
  where
    isValidChar c = isAlphaNum c || c == ' ' || c == '-'
    dashify ' ' = '-'
    dashify c   = c
    collapseHyphens [] = []
    collapseHyphens ('-':cs) = '-' : collapseHyphens (dropWhile (== '-') cs)
    collapseHyphens (c:cs) = c : collapseHyphens cs

-- | Trim leading and trailing whitespace
trim :: String -> String
trim = reverse . dropWhile isSpace . reverse . dropWhile isSpace
