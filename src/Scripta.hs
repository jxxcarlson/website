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
    | "```" `isPrefixOf` line =
        -- Code fence: pass through verbatim until closing ```
        let (codeLines, remaining) = spanCodeFence rest
        in line : codeLines ++ processLines linkMap remaining
    | "| " `isPrefixOf` line =
        let (blockLines, remaining) = spanBlock rest
            block = parseBlock line blockLines
        in renderBlock linkMap block ++ processLines linkMap remaining
    | otherwise = processInline linkMap line : processLines linkMap rest

-- | Collect lines inside a code fence until closing ```
spanCodeFence :: [String] -> ([String], [String])
spanCodeFence [] = ([], [])
spanCodeFence (line:rest)
    | "```" `isPrefixOf` line = ([line], rest)  -- Include closing fence
    | otherwise =
        let (more, remaining) = spanCodeFence rest
        in (line : more, remaining)

-- | Process inline Scripta elements in a line
-- Syntax: [prog TITLE FILENAME], [ilink ID], [ilink ID "text"], [i text], [b text], [par]
-- Wiki-style links: [[ID]] or [[ID custom text]]
-- Backtick-delimited code spans are passed through verbatim
processInline :: LinkMap -> String -> String
processInline _ [] = []
processInline linkMap s@(c:cs)
    | c == '`' =
        -- Inline code: pass through verbatim until closing backtick
        let (code, rest) = break (== '`') cs
        in case rest of
            ('`':remaining) -> c : code ++ "`" ++ processInline linkMap remaining
            _ -> c : processInline linkMap cs  -- No closing backtick, continue
    | c == '[' =
        -- Check for wiki-style link [[...]]
        case cs of
            ('[':rest) -> case parseWikiLink linkMap rest of
                Just (html, remaining) -> html ++ processInline linkMap remaining
                Nothing -> c : processInline linkMap cs
            _ -> case parseInlineElement linkMap s of
                Just (html, rest) -> html ++ processInline linkMap rest
                Nothing -> c : processInline linkMap cs
    | otherwise = c : processInline linkMap cs

-- | Parse wiki-style link [[ID]] or [[ID custom text]]
-- Input starts after the opening [[
-- Returns Just (rendered HTML, remaining string after ]]) or Nothing
parseWikiLink :: LinkMap -> String -> Maybe (String, String)
parseWikiLink linkMap s = do
    -- Find closing ]]
    idx <- findDoubleClosingBracket s
    let inner = take idx s
        rest = drop (idx + 2) s  -- drop ]]
        parts = words inner
    case parts of
        [] -> Nothing
        [zettelId] -> Just (renderInlineLink linkMap zettelId Nothing, rest)
        (zettelId:textParts) -> Just (renderInlineLink linkMap zettelId (Just $ unwords textParts), rest)

-- | Find closing ]] in string
findDoubleClosingBracket :: String -> Maybe Int
findDoubleClosingBracket s = findAt 0 s
  where
    findAt _ [] = Nothing
    findAt n (']':']':_) = Just n
    findAt n (_:rest) = findAt (n + 1) rest

-- | Try to parse an inline element starting with '['
-- Returns Just (rendered HTML, remaining string) or Nothing
-- Supports quoted values: [prog "Title With Spaces" filename.html]
-- Supports nesting: [i [b nested bold italic]]
parseInlineElement :: LinkMap -> String -> Maybe (String, String)
parseInlineElement linkMap s = do
    -- Find the closing bracket
    let content = drop 1 s  -- drop '['
    idx <- findClosingBracket content 0
    let inner = take idx content
        rest = drop (idx + 1) content
        -- Extract command (first word) and argument content (rest)
        (cmd, argRest) = break isSpace (dropWhile isSpace inner)
        argContent = dropWhile isSpace argRest
        -- For commands that need multiple parsed arguments
        parts = parseQuotedWords inner
    case cmd of
        -- Text-wrapping elements: recursively process content
        "i" | not (null argContent) ->
            Just ("<em>" ++ processInline linkMap argContent ++ "</em>", rest)
        "b" | not (null argContent) ->
            Just ("<strong>" ++ processInline linkMap argContent ++ "</strong>", rest)
        "u" | not (null argContent) ->
            Just ("<u>" ++ processInline linkMap argContent ++ "</u>", rest)
        "strike" | not (null argContent) ->
            Just ("<s>" ++ processInline linkMap argContent ++ "</s>", rest)
        -- Other elements use parsed arguments
        "prog" -> case parts of
            (_:title:filename:_) -> Just (renderInlineProg title filename, rest)
            _ -> Nothing
        "hrule" -> case parts of
            ["hrule"] -> Just (renderInlineHrule Nothing, rest)
            ["hrule", width] -> Just (renderInlineHrule (Just width), rest)
            _ -> Nothing
        "ilink" -> case parts of
            ["ilink", zettelId] -> Just (renderInlineLink linkMap zettelId Nothing, rest)
            ["ilink", zettelId, customText] -> Just (renderInlineLink linkMap zettelId (Just customText), rest)
            _ -> Nothing
        "link" -> case parts of
            ("link":args) | length args >= 2 ->
                -- Last word is URL, everything else is label
                let url = last args
                    label = unwords (init args)
                in Just ("<a href=\"" ++ url ++ "\" target=\"_blank\" rel=\"noopener noreferrer\">" ++ label ++ "</a>", rest)
            _ -> Nothing
        "par" -> Just ("<p class=\"par\"></p>", rest)
        "vspace" -> case parts of
            ["vspace", pixels] -> Just ("<div style=\"height: " ++ pixels ++ "px;\"></div>", rest)
            _ -> Nothing
        "box" -> Just ("<span class=\"checkbox\">☐</span>", rest)
        "cbox" -> Just ("<span class=\"checkbox checked\">☑</span>", rest)
        "cite" -> case parts of
            ["cite", label] -> Just (renderCite label, rest)
            _ -> Nothing
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
findClosingBracket s idx = go s idx 0
  where
    go [] _ _ = Nothing
    go (c:cs) i depth
        | c == ']' && depth == 0 = Just i
        | c == ']' = go cs (i + 1) (depth - 1)
        | c == '[' = go cs (i + 1) (depth + 1)
        | otherwise = go cs (i + 1) depth

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

-- | Render citation link
-- [cite WF1977] renders as clickable [WF1977] that scrolls to the bibitem
renderCite :: String -> String
renderCite label =
    "<a href=\"#bib-" ++ label ++ "\" class=\"citation\" data-cite=\"" ++ label ++ "\">[" ++ label ++ "]</a>"

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

-- | Get first line of block content (typically a filename)
getBlockFile :: Block -> String
getBlockFile block = case blockContent block of
    (f:_) -> trim f
    [] -> ""

-- | Wrap content in expandable link (opens in lightbox overlay on click)
wrapExpandable :: String -> String -> String
wrapExpandable url content =
    "<a href=\"" ++ url ++ "\" onclick=\"openLightbox(this.href); return false;\">" ++ content ++ "</a>"

-- | Process block content through inline processor
processBlockContent :: LinkMap -> Block -> String
processBlockContent linkMap block = unlines $ map (processInline linkMap) (blockContent block)

-- | Render a block to HTML lines
renderBlock :: LinkMap -> Block -> [String]
renderBlock linkMap block = case blockType block of
    "image"     -> renderImage block
    "slideshow" -> renderSlideshow block
    "pdf"       -> renderPdf block
    "audio"     -> renderAudio block
    "prog"      -> renderProg block
    "video"     -> renderVideo block
    "center"    -> renderCenter linkMap block
    "vspace"    -> renderVspace block
    "equation"  -> renderEquation block
    "theorem"   -> renderTheorem linkMap block
    "quotation" -> renderQuotation linkMap block
    "indent"    -> renderIndent linkMap block
    "bibitem"   -> renderBibitem linkMap block
    "numbered-sections" -> renderNumberedSections linkMap block
    "gallery"   -> renderGallery block
    "hide"      -> []  -- Hidden content, renders nothing
    _ -> ["<!-- Unknown Scripta block: " ++ blockType block ++ " -->"]

-- | Render a center block
renderCenter :: LinkMap -> Block -> [String]
renderCenter linkMap block =
    let content = processBlockContent linkMap block
    in ["<div style=\"text-align: center;\">", content, "</div>"]

-- | Render an indent block
-- Syntax: | indent        (default 2em indent)
--         | indent 40     (40px indent)
renderIndent :: LinkMap -> Block -> [String]
renderIndent linkMap block =
    let content = processBlockContent linkMap block
        indent = case blockArgs block of
            (n:_) -> n ++ "px"
            []    -> "2em"
    in ["<div style=\"margin-left: " ++ indent ++ ";\">", content, "</div>"]

-- | Render a vspace block (vertical space)
-- Syntax: | vspace 20  (inserts 20 pixels of vertical space)
renderVspace :: Block -> [String]
renderVspace block =
    let pixels = case blockArgs block of
            (n:_) -> n
            [] -> "0"
    in ["<div style=\"height: " ++ pixels ++ "px;\"></div>"]

-- | Render an equation block (LaTeX display math)
-- Syntax: | equation
--         \int_0^{\infty} e^{-x^2} dx = \frac{\sqrt{\pi}}{2}
-- Renders as display-mode LaTeX equation using KaTeX
-- If the body contains '&', wrap in aligned environment for multi-line equations
renderEquation :: Block -> [String]
renderEquation block =
    let latex = trim (unlines (blockContent block))
        hasAlignment = '&' `elem` latex
        body = if hasAlignment
               then "\\begin{aligned}\n" ++ latex ++ "\n\\end{aligned}"
               else latex
    in [ "<div class=\"equation\">"
       , "$$"
       , body
       , "$$"
       , "</div>"
       ]

-- | Render a theorem block
-- Syntax: | theorem (Euclid)
--         There are infinitely many prime numbers
-- The argument (e.g., "Euclid" or "(Euclid)") is optional
renderTheorem :: LinkMap -> Block -> [String]
renderTheorem linkMap block =
    let name = case blockArgs block of
            (n:_) -> " " ++ n
            [] -> ""
        content = processBlockContent linkMap block
    in [ "<div class=\"theorem\">"
       , "<span class=\"theorem-label\">Theorem" ++ name ++ ".</span> " ++ trim content
       , "</div>"
       ]

-- | Render a quotation block
-- Syntax: | quotation title:Gettysburg Address
--         To be or not to be...
-- Renders indented and italicized; optional title in bold above
renderQuotation :: LinkMap -> Block -> [String]
renderQuotation linkMap block =
    let content = processBlockContent linkMap block
        title = getProp "title" block
        titleHtml = case title of
            Just t  -> ["<div class=\"quotation-title\"><strong>" ++ t ++ "</strong></div>"]
            Nothing -> []
    in titleHtml ++
       [ "<div class=\"quotation\">"
       , trim content
       , "</div>"
       ]

-- | Render a bibliography item
-- Syntax: | bibitem WF1977
--         Woese & Fox (1977), "Phylogenetic structure..."
-- Renders as: [WF1977] Woese & Fox (1977), "Phylogenetic structure..."
-- with an anchor for citations to link to
renderBibitem :: LinkMap -> Block -> [String]
renderBibitem linkMap block =
    let label = case blockArgs block of
            (l:_) -> l
            []    -> "?"
        content = trim $ processBlockContent linkMap block
    in [ "<div class=\"bibitem\" id=\"bib-" ++ label ++ "\">"
       , "<span class=\"bibitem-label\">[" ++ label ++ "]</span> " ++ content
       , "</div>"
       ]

-- | Render numbered sections block
-- Syntax: | numbered-sections
--         ## Section 1
--         content...
--         ### Subsection 1.1
--         more content...
-- Wraps content in a div that enables automatic section numbering
renderNumberedSections :: LinkMap -> Block -> [String]
renderNumberedSections linkMap block =
    let content = processBlockContent linkMap block
    in [ "<div class=\"numbered-sections\">"
       , content
       , "</div>"
       ]

-- | Render an image block
-- Args: background (makes it a background image)
-- Props: width, caption, float, display (row for horizontal arrangement, fullwidth for 100% width)
-- If the body starts with "https://", it's treated as a URL; otherwise as a local file path
renderImage :: Block -> [String]
renderImage block =
    let display = getProp "display" block
        isBackground = hasArg "background" block
    in case display of
        Just "row" -> renderImageRow block
        Just "fullwidth" -> renderFullwidthImage block
        _ ->
            let filename = getBlockFile block
                imgPath = toImagePath filename
            in if isBackground
               then renderBackgroundImage imgPath block
               else renderNormalImage imgPath block

-- | Convert filename/URL to image path
-- If it starts with "https://", use as-is; otherwise prepend /media/images/
toImagePath :: String -> String
toImagePath s
    | "https://" `isPrefixOf` s = s
    | otherwise = "/media/images/" ++ s

-- | Render multiple images in a horizontal row
-- Syntax: | image expandable display:row width:200
--         img1.webp, img2.webp, img3.webp
-- Args: expandable (click opens image in new window)
renderImageRow :: Block -> [String]
renderImageRow block =
    let content = getBlockFile block
        -- Split by comma and trim each filename
        filenames = map trim $ splitOn ',' content
        width = fromMaybe "200" (getProp "width" block)
        isExpandable = hasArg "expandable" block
        makeImg f =
            let imgPath = toImagePath f
                imgTag = "<img src=\"" ++ imgPath ++ "\" width=\"" ++ width ++ "\" style=\"margin-right: 0.5em;\">"
            in if isExpandable then wrapExpandable imgPath imgTag else imgTag
        imgTags = map makeImg filenames
    in ["<div style=\"display: flex; flex-wrap: wrap; gap: 0.5em;\">"]
       ++ map ("  " ++) imgTags
       ++ ["</div>"]

-- | Render a full-width image
-- Syntax: | image display:fullwidth caption:My Image
--         myimage.webp
renderFullwidthImage :: Block -> [String]
renderFullwidthImage block =
    let filename = getBlockFile block
        imgPath = toImagePath filename
        caption = getProp "caption" block
        altText = fromMaybe (takeFileName imgPath) caption
        imgTag = "<img src=\"" ++ imgPath ++ "\" style=\"width: 100%;\" alt=\"" ++ altText ++ "\">"
    in case caption of
        Just cap ->
            [ "<figure style=\"margin: 1.5rem 0; width: 100%;\">"
            , "  " ++ imgTag
            , "  <figcaption>" ++ cap ++ "</figcaption>"
            , "</figure>"
            ]
        Nothing -> [imgTag]

-- | Split a string by a delimiter
splitOn :: Char -> String -> [String]
splitOn _ [] = []
splitOn delim s =
    let (first, rest) = break (== delim) s
    in first : case rest of
        [] -> []
        (_:xs) -> splitOn delim xs

-- | Render a normal inline image
-- Args: expandable (click opens image in new tab)
-- Props: width, height, caption, float (left/right for text wrapping), ilink (clickable link URL)
-- URL images (https://) default to 100% width unless width is specified
renderNormalImage :: String -> Block -> [String]
renderNormalImage imgPath block =
    let width = getProp "width" block
        height = getProp "height" block
        caption = getProp "caption" block
        floatDir = getProp "float" block
        imageLink = getProp "ilink" block
        isExpandable = hasArg "expandable" block
        isUrl = "https://" `isPrefixOf` imgPath
        -- URL images default to 100% width; local images have no default
        widthStyle = case (width, isUrl) of
            (Just w, _)     -> " style=\"width: " ++ addPxIfNeeded w ++ ";\""
            (Nothing, True) -> " style=\"width: 100%;\""
            (Nothing, False) -> ""
        heightAttr = maybe "" (\h -> " height=\"" ++ h ++ "\"") height
        altText = fromMaybe (takeFileName imgPath) caption
        imgTag = "<img src=\"" ++ imgPath ++ "\"" ++ widthStyle ++ heightAttr ++ " alt=\"" ++ altText ++ "\">"
        -- Wrap in link: ilink takes priority, then expandable (opens in new window), then no link
        linkedImg = case imageLink of
            Just url -> "<a href=\"" ++ url ++ "\">" ++ imgTag ++ "</a>"
            Nothing | isExpandable -> wrapExpandable imgPath imgTag
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
        (Nothing, Nothing) -> ["<div>" ++ linkedImg ++ "</div>"]

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
    let filename = getBlockFile block
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
    let filename = getBlockFile block
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
    let filename = getBlockFile block
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
    let url = getBlockFile block
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
-- Args: expandable (click opens image in new tab)
-- Props: width, height (use one or both to constrain image size)
renderSlideshow :: Block -> [String]
renderSlideshow block =
    let slides = parseSlides (blockContent block)
        width = getProp "width" block
        height = getProp "height" block
        isExpandable = hasArg "expandable" block
        -- Default to width:600 if neither specified
        (finalWidth, finalHeight) = case (width, height) of
            (Nothing, Nothing) -> (Just "600", Nothing)
            _ -> (width, height)
        total = length slides
        slideHtml = concatMap (renderSlide finalWidth finalHeight isExpandable) (zip [0..] slides)
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
renderSlide :: Maybe String -> Maybe String -> Bool -> (Int, (String, Maybe String)) -> [String]
renderSlide width height expandable (idx, (path, caption)) =
    let imgPath = toImagePath path
        activeClass = if idx == 0 then " active" else ""
        -- Use inline style for dimensions to override CSS
        styleAttr = case (width, height) of
            (Just w, Just h) -> " style=\"width: " ++ w ++ "px; height: " ++ h ++ "px;\""
            (Just w, Nothing) -> " style=\"width: " ++ w ++ "px;\""
            (Nothing, Just h) -> " style=\"height: " ++ h ++ "px;\""
            (Nothing, Nothing) -> ""
        imgTag = "<img src=\"" ++ imgPath ++ "\"" ++ styleAttr ++ ">"
        linkedImg = if expandable then wrapExpandable imgPath imgTag else imgTag
        captionHtml = maybe "" (\c -> "<div class=\"slide-caption\">" ++ c ++ "</div>") caption
    in [ "<div class=\"slide" ++ activeClass ++ "\" data-index=\"" ++ show idx ++ "\">"
       , linkedImg
       , captionHtml
       , "</div>"
       ]

-- | Render a gallery block
-- Syntax: | gallery height:300 title:The Earth
--         earth/image1.webp, Caption One
--         earth/image2.webp, Caption Two
-- Args: expandable (click opens image in lightbox)
-- Props: height (default 300), title (optional)
renderGallery :: Block -> [String]
renderGallery block =
    let items = parseGalleryItems (blockContent block)
        height = fromMaybe "300" (getProp "height" block)
        title = getProp "title" block
        isExpandable = hasArg "expandable" block
        total = length items
        titleHtml = case title of
            Just t  -> ["<div class=\"gallery-title\">" ++ t ++ "</div>"]
            Nothing -> []
        itemsHtml = concatMap (renderGalleryItem height isExpandable) (zip [0..] items)
        -- Store captions as JSON for JavaScript
        captions = "[" ++ intercalate "," (map (\(_,c) -> "\"" ++ escapeJs c ++ "\"") items) ++ "]"
    in [ "<div class=\"gallery\" data-total=\"" ++ show total ++ "\" data-captions='" ++ captions ++ "'>" ]
       ++ titleHtml
       ++ [ "<div class=\"gallery-image-container\">" ]
       ++ itemsHtml
       ++ [ "</div>"
          , "<div class=\"gallery-controls\">"
          , "<button class=\"gallery-btn gallery-prev\" onclick=\"galleryPrev(this)\">&#9664;</button>"
          , "<span class=\"gallery-caption\">" ++ (if null items then "" else snd (head items)) ++ "</span>"
          , "<span class=\"gallery-counter\">(1/" ++ show total ++ ")</span>"
          , "<button class=\"gallery-btn gallery-next\" onclick=\"galleryNext(this)\">&#9654;</button>"
          , "</div>"
          , "</div>"
          , "<script>"
          , "// Initialize gallery for direct page visits (dynamic loader handles dynamic loads)"
          , "if (typeof initializeGalleries === 'function') {"
          , "  initializeGalleries(document);"
          , "} else {"
          , "  // Fallback: set activeGallery if only one gallery on page"
          , "  var galleries = document.querySelectorAll('.gallery');"
          , "  if (galleries.length >= 1) { window.activeGallery = galleries[0]; }"
          , "}"
          , "</script>"
          ]

-- | Parse gallery content lines: "path, caption"
parseGalleryItems :: [String] -> [(String, String)]
parseGalleryItems = map parseGalleryLine . filter (not . all isSpace)
  where
    parseGalleryLine line =
        case break (== ',') line of
            (path, ',':caption) -> (trim path, trim caption)
            (path, _) -> (trim path, "")

-- | Render a single gallery item
renderGalleryItem :: String -> Bool -> (Int, (String, String)) -> [String]
renderGalleryItem height expandable (idx, (path, _)) =
    let imgPath = toImagePath path
        activeClass = if idx == 0 then " active" else ""
        styleAttr = " style=\"height: " ++ height ++ "px;\""
        imgTag = "<img src=\"" ++ imgPath ++ "\"" ++ styleAttr ++ ">"
        linkedImg = if expandable then wrapExpandable imgPath imgTag else imgTag
    in [ "<div class=\"gallery-item" ++ activeClass ++ "\" data-index=\"" ++ show idx ++ "\">"
       , linkedImg
       , "</div>"
       ]

-- | Escape string for JavaScript
escapeJs :: String -> String
escapeJs = concatMap escapeChar
  where
    escapeChar '"' = "\\\""
    escapeChar '\\' = "\\\\"
    escapeChar '\n' = "\\n"
    escapeChar c = [c]

-- | Intercalate (join with separator)
intercalate :: String -> [String] -> String
intercalate _ [] = []
intercalate _ [x] = x
intercalate sep (x:xs) = x ++ sep ++ intercalate sep xs

-- | Extract filename from path
takeFileName :: String -> String
takeFileName = reverse . takeWhile (/= '/') . reverse

-- | Add "px" suffix to numeric values (e.g., "600" -> "600px", "50%" -> "50%")
addPxIfNeeded :: String -> String
addPxIfNeeded s
    | all isDigit s = s ++ "px"
    | otherwise = s
  where
    isDigit c = c >= '0' && c <= '9'

-- | Trim whitespace from both ends
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
