{-# LANGUAGE OverloadedStrings #-}

module Scripta (processScripta, LinkMap) where

import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Char (isSpace)
import qualified Data.Map as M

-- | Map from Zettelkasten ID to (URL, Title)
type LinkMap = M.Map String (String, String)

-- | Process Scripta blocks and inline elements in markdown content
processScripta :: LinkMap -> String -> String
processScripta linkMap = unlines . processLines linkMap . lines

processLines :: LinkMap -> [String] -> [String]
processLines _ [] = []
processLines linkMap (line:rest)
    | "| " `isPrefixOf` line =
        let (blockLines, remaining) = spanBlock rest
            block = parseBlock line blockLines
        in renderBlock block ++ processLines linkMap remaining
    | otherwise = processInline linkMap line : processLines linkMap rest

-- | Process inline Scripta elements in a line
-- Syntax: [prog TITLE FILENAME], [ilink ID], [ilink ID "text"]
processInline :: LinkMap -> String -> String
processInline _ [] = []
processInline linkMap s@(c:cs)
    | c == '[' =
        case parseInlineElement linkMap s of
            Just (html, rest) -> html ++ processInline linkMap rest
            Nothing -> c : processInline linkMap cs
    | otherwise = c : processInline linkMap cs

-- | Try to parse an inline element starting with '['
-- Returns Just (rendered HTML, remaining string) or Nothing
-- Supports quoted values: [prog "Title With Spaces" filename.html]
parseInlineElement :: LinkMap -> String -> Maybe (String, String)
parseInlineElement linkMap s = do
    -- Find the closing bracket
    let content = drop 1 s  -- drop '['
    idx <- findClosingBracket content 0
    let inner = take idx content
        rest = drop (idx + 1) content
        parts = parseQuotedWords inner
    case parts of
        ("prog":title:filename:_) ->
            Just (renderInlineProg title filename, rest)
        ["hrule"] ->
            Just (renderInlineHrule Nothing, rest)
        ["hrule", width] ->
            Just (renderInlineHrule (Just width), rest)
        ["ilink", zettelId] ->
            Just (renderInlineLink linkMap zettelId Nothing, rest)
        ["ilink", zettelId, customText] ->
            Just (renderInlineLink linkMap zettelId (Just customText), rest)
        _ -> Nothing

-- | Parse words, treating quoted strings as single words
parseQuotedWords :: String -> [String]
parseQuotedWords [] = []
parseQuotedWords s =
    let s' = dropWhile isSpace s
    in case s' of
        [] -> []
        ('"':rest) ->
            let (quoted, after) = break (== '"') rest
                remaining = drop 1 after  -- drop closing quote
            in quoted : parseQuotedWords remaining
        _ ->
            let (word, after) = break isSpace s'
            in word : parseQuotedWords after

-- | Find closing bracket, handling nesting
findClosingBracket :: String -> Int -> Maybe Int
findClosingBracket [] _ = Nothing
findClosingBracket (c:cs) idx
    | c == ']' = Just idx
    | c == '[' = Nothing  -- Don't handle nested brackets
    | otherwise = findClosingBracket cs (idx + 1)

-- | Render inline prog element as external link
renderInlineProg :: String -> String -> String
renderInlineProg title filename =
    let progPath = "/prog/" ++ filename
    in "<a href=\"" ++ progPath ++ "\" target=\"_blank\" class=\"prog-link\">" ++ title ++ "</a>"

-- | Render inline hrule element
-- [hrule] renders a full-width horizontal rule
-- [hrule 100] renders a 100px wide rule, centered
-- Adds spacing below the rule
renderInlineHrule :: Maybe String -> String
renderInlineHrule Nothing = "<hr style=\"margin-bottom: 1em;\">"
renderInlineHrule (Just width) =
    "<hr style=\"width: " ++ width ++ "px; margin-left: auto; margin-right: auto; margin-bottom: 1em;\">"

-- | Render inline link to another note/post
-- [ilink 202601170832] renders link with title as text
-- [ilink 202601170832 "custom text"] renders link with custom text
renderInlineLink :: LinkMap -> String -> Maybe String -> String
renderInlineLink linkMap zettelId customText =
    case M.lookup zettelId linkMap of
        Just (url, title) ->
            let linkText = fromMaybe title customText
            in "<a href=\"" ++ url ++ "\" class=\"internal-link\">" ++ linkText ++ "</a>"
        Nothing ->
            -- Fallback: link to archive path if not found in map
            let url = "/archive/" ++ zettelId ++ ".html"
                linkText = fromMaybe zettelId customText
            in "<a href=\"" ++ url ++ "\" class=\"internal-link broken\">" ++ linkText ++ "</a>"

-- | Collect lines belonging to a block (non-empty lines after the header)
spanBlock :: [String] -> ([String], [String])
spanBlock ls =
    let (content, rest) = span isBlockContent ls
    in (content, dropWhile isEmpty rest)
  where
    isBlockContent s = not (null s) && not ("| " `isPrefixOf` s)
    isEmpty = all isSpace

-- | Parsed Scripta block
-- blockArgs: positional arguments (words without colons)
-- blockProps: key-value properties (key:value pairs, values may have spaces)
data Block = Block
    { blockType :: String
    , blockArgs :: [String]
    , blockProps :: [(String, String)]
    , blockContent :: [String]
    } deriving (Show)

-- | Parse a block header and content
-- Syntax: | blocktype ARG1 ARG2 ... PROP1:VALUE1 PROP2:VALUE2 ...
-- ARGs have no colons, PROPs have colons, VALUES may have spaces
parseBlock :: String -> [String] -> Block
parseBlock header content =
    let headerContent = drop 2 header  -- drop "| "
        (btype, rest) = parseBlockType headerContent
        (args, props) = parseArgsAndProps rest
    in Block btype args props content

-- | Extract block type (first word)
parseBlockType :: String -> (String, String)
parseBlockType s =
    let s' = dropWhile isSpace s
        (btype, rest) = break isSpace s'
    in (btype, dropWhile isSpace rest)

-- | Parse arguments and properties from the header remainder
-- Args are words without colons, Props are key:value pairs
parseArgsAndProps :: String -> ([String], [(String, String)])
parseArgsAndProps s = go (words s) [] []
  where
    go [] args props = (reverse args, reverse props)
    go (w:ws) args props
        | ':' `elem` w =
            -- This is a property; collect value which may span multiple words
            let (key, _:valStart) = break (== ':') w
                (valRest, remaining) = collectValue ws
                value = unwords (valStart : valRest)
            in go remaining args ((key, value) : props)
        | otherwise =
            -- This is an argument
            go ws (w : args) props

    -- Collect words until we hit another key:value or end
    collectValue [] = ([], [])
    collectValue (w:ws)
        | ':' `elem` w = ([], w:ws)  -- Next property starts
        | otherwise =
            let (more, rest) = collectValue ws
            in (w : more, rest)

-- | Check if an argument is present
hasArg :: String -> Block -> Bool
hasArg arg block = arg `elem` blockArgs block

-- | Look up a property value
getProp :: String -> Block -> Maybe String
getProp key block = lookup key (blockProps block)

-- | Render a block to HTML lines
renderBlock :: Block -> [String]
renderBlock block = case blockType block of
    "image"     -> renderImage block
    "slideshow" -> renderSlideshow block
    "pdf"       -> renderPdf block
    "audio"     -> renderAudio block
    "prog"      -> renderProg block
    "video"     -> renderVideo block
    "center"    -> renderCenter block
    "vspace"    -> renderVspace block
    "hide"      -> []  -- Hidden content, renders nothing
    _ -> ["<!-- Unknown Scripta block: " ++ blockType block ++ " -->"]

-- | Render a center block
renderCenter :: Block -> [String]
renderCenter block =
    let content = unlines (blockContent block)
    in ["<div style=\"text-align: center;\">", content, "</div>"]

-- | Render a vspace block (vertical space)
-- Syntax: | vspace 20  (inserts 20 pixels of vertical space)
renderVspace :: Block -> [String]
renderVspace block =
    let pixels = case blockArgs block of
            (n:_) -> n
            [] -> "0"
    in ["<div style=\"height: " ++ pixels ++ "px;\"></div>"]

-- | Render an image block
-- Args: background (makes it a background image)
-- Props: width, caption, float, display (row for horizontal arrangement)
renderImage :: Block -> [String]
renderImage block =
    let display = getProp "display" block
        isBackground = hasArg "background" block
    in case display of
        Just "row" -> renderImageRow block
        _ ->
            let filename = case blockContent block of
                    (f:_) -> trim f
                    [] -> ""
                imgPath = "/media/images/" ++ filename
            in if isBackground
               then renderBackgroundImage imgPath block
               else renderNormalImage imgPath block

-- | Render multiple images in a horizontal row
-- Syntax: | image display:row width:200
--         img1.webp, img2.webp, img3.webp
renderImageRow :: Block -> [String]
renderImageRow block =
    let content = case blockContent block of
            (c:_) -> c
            [] -> ""
        -- Split by comma and trim each filename
        filenames = map trim $ splitOn ',' content
        width = fromMaybe "200" (getProp "width" block)
        imgTags = map (\f -> "<img src=\"/media/images/" ++ f ++ "\" width=\"" ++ width ++ "\" style=\"margin-right: 0.5em;\">") filenames
    in ["<div style=\"display: flex; flex-wrap: wrap; gap: 0.5em;\">"]
       ++ map ("  " ++) imgTags
       ++ ["</div>"]

-- | Split a string by a delimiter
splitOn :: Char -> String -> [String]
splitOn _ [] = []
splitOn delim s =
    let (first, rest) = break (== delim) s
    in first : case rest of
        [] -> []
        (_:xs) -> splitOn delim xs

-- | Render a normal inline image
-- Props: width, caption, float (left/right for text wrapping), ilink (clickable link URL)
renderNormalImage :: String -> Block -> [String]
renderNormalImage imgPath block =
    let width = getProp "width" block
        caption = getProp "caption" block
        floatDir = getProp "float" block
        imageLink = getProp "ilink" block
        widthAttr = maybe "" (\w -> " width=\"" ++ w ++ "\"") width
        altText = fromMaybe (takeFileName imgPath) caption
        imgTag = "<img src=\"" ++ imgPath ++ "\"" ++ widthAttr ++ " alt=\"" ++ altText ++ "\">"
        -- Wrap in link if ilink property is present
        linkedImg = case imageLink of
            Just url -> "<a href=\"" ++ url ++ "\">" ++ imgTag ++ "</a>"
            Nothing  -> imgTag
        -- Float styling with margin for text spacing
        floatStyle = case floatDir of
            Just "left"  -> "float: left; margin-top: 0.5rem; margin-right: 1.5em; margin-bottom: 1em;"
            Just "right" -> "float: right; margin-top: 0.5rem; margin-left: 1.5em; margin-bottom: 1em;"
            _ -> ""
    in case (caption, floatDir) of
        (Just cap, Just _) ->
            [ "<figure style=\"" ++ floatStyle ++ "\">"
            , "  " ++ linkedImg
            , "  <figcaption>" ++ cap ++ "</figcaption>"
            , "</figure>"
            ]
        (Just cap, Nothing) ->
            [ "<figure>"
            , "  " ++ linkedImg
            , "  <figcaption>" ++ cap ++ "</figcaption>"
            , "</figure>"
            ]
        (Nothing, Just _) ->
            [ "<div style=\"" ++ floatStyle ++ "\">" ++ linkedImg ++ "</div>" ]
        (Nothing, Nothing) -> [linkedImg]

-- | Render a background image
-- If opacity is specified, sets entire page background
-- Otherwise renders as full-width hero style div
renderBackgroundImage :: String -> Block -> [String]
renderBackgroundImage imgPath block =
    let opacity = getProp "opacity" block
        caption = getProp "caption" block
    in case opacity of
        Just op ->
            -- Page-wide background with opacity using ::before pseudo-element
            [ "<style>"
            , "body { position: relative; }"
            , "body::before {"
            , "  content: \"\";"
            , "  position: fixed;"
            , "  top: 0;"
            , "  left: 0;"
            , "  width: 100%;"
            , "  height: 100%;"
            , "  background-image: url('" ++ imgPath ++ "');"
            , "  background-size: cover;"
            , "  background-position: center;"
            , "  opacity: " ++ op ++ ";"
            , "  z-index: -1;"
            , "  pointer-events: none;"
            , "}"
            , "</style>"
            ]
        Nothing ->
            -- Hero-style background div
            let height = fromMaybe "300" (getProp "height" block)
                captionHtml = maybe [] (\c -> ["<div class=\"bg-caption\">" ++ c ++ "</div>"]) caption
            in [ "<div class=\"background-image\" style=\"background-image: url('" ++ imgPath ++ "'); height: " ++ height ++ "px;\">"
               , "</div>"
               ] ++ captionHtml

-- | Render a PDF block
-- Props: width (default 100%), height (default 600px)
-- Content: path to PDF file
renderPdf :: Block -> [String]
renderPdf block =
    let filename = case blockContent block of
            (f:_) -> trim f
            [] -> ""
        pdfPath = "/media/pdf/" ++ filename
        width = fromMaybe "100%" (getProp "width" block)
        height = fromMaybe "600px" (getProp "height" block)
    in [ "<object data=\"" ++ pdfPath ++ "\" type=\"application/pdf\" width=\"" ++ width ++ "\" height=\"" ++ height ++ "\">"
       , "<p>Unable to display PDF. <a href=\"" ++ pdfPath ++ "\">Download PDF</a></p>"
       , "</object>"
       ]

-- | Render an audio block
-- Props: title (clickable title that plays audio)
-- Content: path to audio file
renderAudio :: Block -> [String]
renderAudio block =
    let filename = case blockContent block of
            (f:_) -> trim f
            [] -> ""
        audioPath = "/media/audio/" ++ filename
        title = fromMaybe filename (getProp "title" block)
        audioId = "audio-" ++ filter (`elem` (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'])) filename
    in [ "<div class=\"audio-block\">"
       , "<a href=\"#\" id=\"" ++ audioId ++ "-link\" class=\"audio-title\" onclick=\"toggleAudio('" ++ audioId ++ "'); return false;\">" ++ title ++ "</a>"
       , "<audio id=\"" ++ audioId ++ "\" src=\"" ++ audioPath ++ "\" onended=\"document.getElementById('" ++ audioId ++ "-link').classList.remove('playing');\"></audio>"
       , "</div>"
       , "<script>"
       , "function toggleAudio(id) {"
       , "  var a = document.getElementById(id);"
       , "  var link = document.getElementById(id + '-link');"
       , "  if (a.paused) { a.play(); link.classList.add('playing'); }"
       , "  else { a.pause(); link.classList.remove('playing'); }"
       , "}"
       , "</script>"
       ]

-- | Render a prog block (embedded HTML app)
-- Props: title, width, height, display (external opens in new window)
-- Content: path to HTML file in /prog/
renderProg :: Block -> [String]
renderProg block =
    let filename = case blockContent block of
            (f:_) -> trim f
            [] -> ""
        progPath = "/prog/" ++ filename
        title = fromMaybe filename (getProp "title" block)
        display = getProp "display" block
        width = fromMaybe "600" (getProp "width" block)
        height = fromMaybe "400" (getProp "height" block)
    in case display of
        Just "external" ->
            [ "<div class=\"prog-block prog-external\">"
            , "<a href=\"" ++ progPath ++ "\" target=\"_blank\" class=\"prog-link\">" ++ title ++ "</a>"
            , "</div>"
            ]
        _ ->
            [ "<div class=\"prog-block\">"
            , "<div class=\"prog-title\">" ++ title ++ "</div>"
            , "<iframe src=\"" ++ progPath ++ "\" width=\"" ++ width ++ "\" height=\"" ++ height ++ "\" frameborder=\"0\"></iframe>"
            , "</div>"
            ]

-- | Render a video block (Vimeo or YouTube embed)
-- Props: width, height, caption
-- Content: video URL
renderVideo :: Block -> [String]
renderVideo block =
    let url = case blockContent block of
            (u:_) -> trim u
            [] -> ""
        caption = fromMaybe "" (getProp "caption" block)
        width = fromMaybe "640" (getProp "width" block)
        height = fromMaybe "360" (getProp "height" block)
        embedUrl = getEmbedUrl url
        captionHtml = if null caption then "" else "<div class=\"video-caption\">" ++ caption ++ "</div>"
    in [ "<div class=\"video-block\">"
       , "<iframe src=\"" ++ embedUrl ++ "\" width=\"" ++ width ++ "\" height=\"" ++ height ++ "\" frameborder=\"0\" allow=\"autoplay; fullscreen; picture-in-picture\" allowfullscreen></iframe>"
       , captionHtml
       , "</div>"
       ]

-- | Convert video URL to embed URL
getEmbedUrl :: String -> String
getEmbedUrl url
    | "vimeo.com/" `isInfixOf` url =
        let videoId = takeWhile (/= '?') $ reverse $ takeWhile (/= '/') $ reverse url
        in "https://player.vimeo.com/video/" ++ videoId ++ "?title=0&byline=0&portrait=0"
    | "youtube.com/watch" `isInfixOf` url =
        let videoId = drop 2 $ dropWhile (/= '=') url
        in "https://www.youtube.com/embed/" ++ takeWhile (/= '&') videoId
    | "youtu.be/" `isInfixOf` url =
        let videoId = reverse $ takeWhile (/= '/') $ reverse $ takeWhile (/= '?') url
        in "https://www.youtube.com/embed/" ++ videoId
    | otherwise = url  -- Use as-is if not recognized

-- | Check if a string is contained in another
isInfixOf :: String -> String -> Bool
isInfixOf needle haystack = any (isPrefixOf needle) (tails haystack)
  where
    tails [] = [[]]
    tails s@(_:xs) = s : tails xs

-- | Render a slideshow block
-- Content lines: path/to/image.png | Caption text
renderSlideshow :: Block -> [String]
renderSlideshow block =
    let slides = parseSlides (blockContent block)
        width = fromMaybe "600" (getProp "width" block)
        total = length slides
        slideHtml = concatMap (renderSlide width) (zip [0..] slides)
    in [ "<div class=\"slideshow\" data-total=\"" ++ show total ++ "\">" ]
       ++ slideHtml
       ++ [ "<div class=\"slideshow-controls\">"
          , "<button class=\"slide-btn slide-first\" onclick=\"slideshowFirst(this)\">⏮</button>"
          , "<button class=\"slide-btn slide-prev\" onclick=\"slideshowPrev(this)\">◀</button>"
          , "<span class=\"slide-counter\"><span class=\"slide-current\">1</span> / " ++ show total ++ "</span>"
          , "<button class=\"slide-btn slide-next\" onclick=\"slideshowNext(this)\">▶</button>"
          , "<button class=\"slide-btn slide-last\" onclick=\"slideshowLast(this)\">⏭</button>"
          , "</div>"
          , "</div>"
          , "<script>"
          , "function slideshowNav(btn, delta) {"
          , "var ss = btn.closest('.slideshow');"
          , "var slides = ss.querySelectorAll('.slide');"
          , "var total = slides.length;"
          , "var current = parseInt(ss.dataset.current || '0');"
          , "slides[current].classList.remove('active');"
          , "current = Math.max(0, Math.min(total - 1, current + delta));"
          , "slides[current].classList.add('active');"
          , "ss.dataset.current = current;"
          , "ss.querySelector('.slide-current').textContent = current + 1;"
          , "}"
          , "function slideshowNext(btn) { slideshowNav(btn, 1); }"
          , "function slideshowPrev(btn) { slideshowNav(btn, -1); }"
          , "function slideshowFirst(btn) { slideshowNav(btn, -9999); }"
          , "function slideshowLast(btn) { slideshowNav(btn, 9999); }"
          , "</script>"
          ]

-- | Parse slide content lines: "path.png | caption" or just "path.png"
parseSlides :: [String] -> [(String, Maybe String)]
parseSlides = map parseSlideLine . filter (not . all isSpace)
  where
    parseSlideLine line =
        case break (== '|') line of
            (path, '|':caption) -> (trim path, Just (trim caption))
            (path, _) -> (trim path, Nothing)

-- | Render a single slide
renderSlide :: String -> (Int, (String, Maybe String)) -> [String]
renderSlide width (idx, (path, caption)) =
    let imgPath = "/media/images/" ++ path
        activeClass = if idx == 0 then " active" else ""
        captionHtml = maybe "" (\c -> "<div class=\"slide-caption\">" ++ c ++ "</div>") caption
    in [ "<div class=\"slide" ++ activeClass ++ "\" data-index=\"" ++ show idx ++ "\">"
       , "<img src=\"" ++ imgPath ++ "\" width=\"" ++ width ++ "\">"
       , captionHtml
       , "</div>"
       ]

-- | Extract filename from path
takeFileName :: String -> String
takeFileName = reverse . takeWhile (/= '/') . reverse

-- | Trim whitespace from both ends
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
