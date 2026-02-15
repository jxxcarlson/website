{-# LANGUAGE OverloadedStrings #-}

module Utils
    ( escapeHtmlAttr
    , getModTime
    , stripHtmlTags
    , monthName
    , takeBaseName'
    , formatZettelDate
    , extractFirstLineTitle
    , toSlug
    , stripFirstLine
    , stripFirstLineTags
    , preprocessScriptaImport
    ) where

import Data.List (isPrefixOf)
import Data.Char (isSpace)
import System.Posix.Files (getFileStatus, modificationTime)

-- | Escape HTML special characters for use in data attributes
escapeHtmlAttr :: String -> String
escapeHtmlAttr = concatMap escapeChar
  where
    escapeChar '<' = "&lt;"
    escapeChar '>' = "&gt;"
    escapeChar '&' = "&amp;"
    escapeChar '"' = "&quot;"
    escapeChar '\n' = " "
    escapeChar c = [c]

-- | Get file modification time as Unix timestamp string
getModTime :: FilePath -> IO String
getModTime path = do
    status <- getFileStatus path
    let mtime = modificationTime status
    return $ show (round (realToFrac mtime :: Double) :: Integer)

-- | Strip HTML tags from content
stripHtmlTags :: String -> String
stripHtmlTags [] = []
stripHtmlTags ('<':xs) = stripHtmlTags $ drop 1 $ dropWhile (/= '>') xs
stripHtmlTags (x:xs) = x : stripHtmlTags xs

-- | Convert month number to name
monthName :: String -> String
monthName "01" = "January";  monthName "02" = "February"; monthName "03" = "March"
monthName "04" = "April";    monthName "05" = "May";      monthName "06" = "June"
monthName "07" = "July";     monthName "08" = "August";   monthName "09" = "September"
monthName "10" = "October";  monthName "11" = "November"; monthName "12" = "December"
monthName m = m

-- | Extract base filename without extension
takeBaseName' :: FilePath -> String
takeBaseName' p = reverse $ drop 1 $ dropWhile (/= '.') $ reverse $
                  reverse $ takeWhile (/= '/') $ reverse p

-- | Format date from Zettelkasten ID (YYYYMMDD...)
formatZettelDate :: String -> String
formatZettelDate filename =
    let zettelId = take 8 filename
        year = take 4 zettelId
        month = take 2 (drop 4 zettelId)
        day = take 2 (drop 6 zettelId)
        dayNum = dropWhile (== '0') day
    in monthName month ++ " " ++ (if null dayNum then "0" else dayNum) ++ ", " ++ year

-- | Extract title from first line of content
-- If line starts with "# ", strip it (markdown heading)
extractFirstLineTitle :: String -> String
extractFirstLineTitle content =
    let contentLines = lines content
    in if not (null contentLines) && not (null (head contentLines))
       then stripMarkdownHeading (head contentLines)
       else "Untitled"
  where
    stripMarkdownHeading line
        | "# " `isPrefixOf` line = drop 2 line
        | "#" `isPrefixOf` line  = drop 1 line
        | otherwise              = line

-- | Convert title to URL-friendly slug
toSlug :: String -> String
toSlug = map toLower . map dashify . filter isValidChar
  where
    isValidChar c = c `elem` (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ " -")
    dashify ' ' = '-'
    dashify c = c
    toLower c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c

-- | Strip the first line (title) from content
stripFirstLine :: String -> String
stripFirstLine = unlines . drop 1 . lines

-- | Strip all tags from the first non-blank line
-- Tags are words starting with '#'. If the line becomes empty after stripping, it's removed.
stripFirstLineTags :: String -> String
stripFirstLineTags content = unlines $ processTagLines (lines content)
  where
    processTagLines [] = []
    processTagLines (l:rest)
        | all isSpace l = l : processTagLines rest  -- Preserve blank lines at start
        | otherwise =
            let stripped = unwords $ filter (not . ("#" `isPrefixOf`)) $ words l
            in if null stripped || all isSpace stripped
               then rest  -- Remove the now-empty tag line
               else stripped : rest  -- Keep the line with remaining content

-- | Preprocess Scripta-format documents
-- Handles: | title\n<TITLE> format, [tags ...] format, and [image ...] format
preprocessScriptaImport :: String -> String
preprocessScriptaImport content =
    let -- First pass: handle [image ...] blocks (may span multiple lines)
        afterImage = processImageBlocks content
        -- Second pass: handle line-based transformations
        ls = lines afterImage
        processed = processScriptaLines ls
    in unlines processed
  where
    -- Process [image ...] blocks, which may span multiple lines
    processImageBlocks [] = []
    processImageBlocks s
        | "[image " `isPrefixOf` s =
            let afterOpen = drop 7 s  -- drop "[image "
                (inner, rest) = spanToClosingBracket afterOpen
                -- Remove line breaks and normalize whitespace
                normalized = unwords $ words inner
            in "| image\n" ++ normalized ++ "\n" ++ processImageBlocks rest
        | otherwise = head s : processImageBlocks (tail s)

    -- Find content up to closing bracket, handling nested content
    spanToClosingBracket :: String -> (String, String)
    spanToClosingBracket s = go [] s
      where
        go acc [] = (reverse acc, [])
        go acc (']':rest) = (reverse acc, rest)
        go acc (c:rest) = go (c:acc) rest

    processScriptaLines [] = []
    processScriptaLines (l:rest)
        -- Handle | title header
        | "| title" == dropWhile isSpace l =
            case rest of
                (titleLine:remaining) -> titleLine : processScriptaLines remaining
                [] -> []
        -- Handle [tags ...] line
        | "[tags " `isPrefixOf` dropWhile isSpace l =
            convertTagsLine l : processScriptaLines rest
        | otherwise = l : processScriptaLines rest

    -- Convert [tags post tag:physics] to #post #tag:physics
    convertTagsLine line =
        let trimmed = dropWhile isSpace line
            -- Extract content between [tags and ]
            inner = drop 6 trimmed  -- drop "[tags "
            content' = takeWhile (/= ']') inner
            tags = words content'
            -- Convert each tag: "post" -> "#post", "tag:physics" -> "#tag:physics"
            convertedTags = map convertTag tags
        in unwords convertedTags

    convertTag tag =
        let cleaned = filter isValidTagChar tag
        in "#" ++ cleaned

    -- Valid tag characters: letters, digits, colon
    isValidTagChar c = c `elem` ['a'..'z'] || c `elem` ['A'..'Z']
                    || c `elem` ['0'..'9'] || c == ':'
