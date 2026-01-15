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
    "image" -> renderImage block
    "hide"  -> []  -- Hidden content, renders nothing
    _ -> ["<!-- Unknown Scripta block: " ++ blockType block ++ " -->"]

-- | Render an image block
-- Args: background (makes it a background image)
-- Props: width, caption
renderImage :: Block -> [String]
renderImage block =
    let filename = case blockContent block of
            (f:_) -> trim f
            [] -> ""
        imgPath = "/images/" ++ filename
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

-- | Extract filename from path
takeFileName :: String -> String
takeFileName = reverse . takeWhile (/= '/') . reverse

-- | Trim whitespace from both ends
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
