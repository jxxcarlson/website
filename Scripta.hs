{-# LANGUAGE OverloadedStrings #-}

module Scripta (processScripta) where

import Data.List (isPrefixOf, stripPrefix)
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
data Block = Block
    { blockType :: String
    , blockAttrs :: [(String, String)]
    , blockContent :: [String]
    } deriving (Show)

-- | Parse a block header and content
parseBlock :: String -> [String] -> Block
parseBlock header content =
    let parts = words (drop 2 header)  -- drop "| "
        (btype, attrs) = case parts of
            [] -> ("unknown", [])
            (t:as) -> (t, map parseAttr as)
    in Block btype attrs content

-- | Parse an attribute like "width:400" into ("width", "400")
parseAttr :: String -> (String, String)
parseAttr s = case break (== ':') s of
    (key, ':':val) -> (key, val)
    (key, _) -> (key, "")

-- | Look up an attribute value
getAttr :: String -> [(String, String)] -> Maybe String
getAttr key attrs = lookup key attrs

-- | Render a block to HTML lines
renderBlock :: Block -> [String]
renderBlock block = case blockType block of
    "image" -> renderImage block
    _ -> ["<!-- Unknown Scripta block: " ++ blockType block ++ " -->"]

-- | Render an image block
renderImage :: Block -> [String]
renderImage block =
    let filename = case blockContent block of
            (f:_) -> trim f
            [] -> ""
        width = getAttr "width" (blockAttrs block)
        caption = getAttr "caption" (blockAttrs block)
        imgPath = "/images/" ++ filename
        widthAttr = maybe "" (\w -> " width=\"" ++ w ++ "\"") width
        imgTag = "<img src=\"" ++ imgPath ++ "\"" ++ widthAttr ++ " alt=\"" ++ fromMaybe filename caption ++ "\">"
    in case caption of
        Just cap ->
            [ "<figure>"
            , "  " ++ imgTag
            , "  <figcaption>" ++ cap ++ "</figcaption>"
            , "</figure>"
            ]
        Nothing -> [imgTag]

-- | Trim whitespace from both ends
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
