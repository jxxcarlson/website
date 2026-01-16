{-# LANGUAGE OverloadedStrings #-}

module Scripta (processScripta) where

import Data.List (isPrefixOf)
import Data.Maybe (fromMaybe)
import Data.Char (isSpace)

-- | Process Scripta blocks in markdown content
processScripta :: String -> String
processScripta = unlines . processLines . lines

processLines :: [String] -> [String]
processLines [] = []
processLines (line:rest)
    | "| " `isPrefixOf` line =
        let (blockLines, remaining) = spanBlock rest
            block = parseBlock line blockLines
        in renderBlock block ++ processLines remaining
    | otherwise = line : processLines rest

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
    "hide"      -> []  -- Hidden content, renders nothing
    _ -> ["<!-- Unknown Scripta block: " ++ blockType block ++ " -->"]

-- | Render an image block
-- Args: background (makes it a background image)
-- Props: width, caption
renderImage :: Block -> [String]
renderImage block =
    let filename = case blockContent block of
            (f:_) -> trim f
            [] -> ""
        imgPath = "/media/images/" ++ filename
        isBackground = hasArg "background" block
    in if isBackground
       then renderBackgroundImage imgPath block
       else renderNormalImage imgPath block

-- | Render a normal inline image
renderNormalImage :: String -> Block -> [String]
renderNormalImage imgPath block =
    let width = getProp "width" block
        caption = getProp "caption" block
        widthAttr = maybe "" (\w -> " width=\"" ++ w ++ "\"") width
        altText = fromMaybe (takeFileName imgPath) caption
        imgTag = "<img src=\"" ++ imgPath ++ "\"" ++ widthAttr ++ " alt=\"" ++ altText ++ "\">"
    in case caption of
        Just cap ->
            [ "<figure>"
            , "  " ++ imgTag
            , "  <figcaption>" ++ cap ++ "</figcaption>"
            , "</figure>"
            ]
        Nothing -> [imgTag]

-- | Render a background image (full-width hero style)
renderBackgroundImage :: String -> Block -> [String]
renderBackgroundImage imgPath block =
    let height = fromMaybe "300" (getProp "height" block)
        caption = getProp "caption" block
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
