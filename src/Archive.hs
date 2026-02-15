{-# LANGUAGE OverloadedStrings #-}

module Archive
    ( findTxtFiles
    , findMdFiles
    , hasPostTag
    , hasTag
    , extractPostCategory
    , extractContentTags
    , scanArchiveForPosts
    , scanArchiveForTag
    , scanArchiveForContentTags
    , buildTagIndex
    , preprocessScriptaImport
    ) where

import qualified Data.Map as M
import Hakyll (Identifier, fromFilePath, toFilePath)
import System.Directory (listDirectory, doesDirectoryExist)
import System.FilePath ((</>), takeExtension)
import Control.Monad (filterM, forM)
import Data.List (isPrefixOf, isInfixOf, find)
import Data.Char (isSpace)
import Data.Maybe (catMaybes)

import Utils (extractFirstLineTitle, preprocessScriptaImport)

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

-- | Find all .md files in a directory
findMdFiles :: FilePath -> IO [Identifier]
findMdFiles dir = do
    exists <- doesDirectoryExist dir
    if not exists
        then return []
        else do
            entries <- listDirectory dir
            let paths = map (dir </>) entries
            files <- filterM (\p -> do
                isDir <- doesDirectoryExist p
                return $ not isDir && takeExtension p == ".md") paths
            subdirs <- filterM doesDirectoryExist paths
            subIdents <- concat <$> mapM findMdFiles subdirs
            return $ map fromFilePath files ++ subIdents

-- | Check if content has a #post tag
hasPostTag :: String -> Bool
hasPostTag content = any isPostLine (lines content)
  where
    isPostLine line = "#post" `isPrefixOf` (dropWhile isSpace line)

-- | Check if content has a specific tag
hasTag :: String -> String -> Bool
hasTag tag content = any isTagLine (lines content)
  where
    isTagLine line = tag `isPrefixOf` (dropWhile isSpace line)

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

-- | Extract all #tag:xyz tags from content
-- Returns list of tag names (the part after #tag:)
-- Finds #tag: anywhere in the content, not just at line start
extractContentTags :: String -> [String]
extractContentTags content = findTags content
  where
    findTags [] = []
    findTags s@(_:rest)
        | "#tag:" `isPrefixOf` s =
            let rawTag = takeWhile (\c -> not (isSpace c) && c /= '\n') (drop 5 s)
                -- Filter to valid tag characters: letters, digits, colon
                tag = filter isValidTagChar rawTag
            in tag : findTags (drop (5 + length rawTag) s)
        | otherwise = findTags rest
    isValidTagChar c = c `elem` ['a'..'z'] || c `elem` ['A'..'Z']
                    || c `elem` ['0'..'9'] || c == ':'

-- | Scan archive directory for files containing #post tags
-- Returns a map of Identifier -> (Maybe category, title)
scanArchiveForPosts :: FilePath -> IO (M.Map Identifier (Maybe String, String))
scanArchiveForPosts dir = do
    files <- findTxtFiles dir
    results <- forM files $ \path -> do
        content <- readFile path
        let preprocessed = preprocessScriptaImport content
            category = extractPostCategory preprocessed
            title = extractFirstLineTitle preprocessed
        return $ if hasPostTag preprocessed
                 then Just (fromFilePath path, (category, title))
                 else Nothing
    return $ M.fromList $ catMaybes results

-- | Scan archive for files containing a specific tag
-- Returns a map of Identifier -> title (from first line)
scanArchiveForTag :: String -> FilePath -> IO (M.Map Identifier String)
scanArchiveForTag tag dir = do
    files <- findTxtFiles dir
    results <- forM files $ \path -> do
        content <- readFile path
        let preprocessed = preprocessScriptaImport content
        return $ if hasTag tag preprocessed
                 then Just (fromFilePath path, head' $ lines preprocessed)
                 else Nothing
    return $ M.fromList $ catMaybes results
  where head' [] = ""; head' (x:_) = x

-- | Scan archive posts for content tags
-- Returns a map of Identifier -> [tag names]
scanArchiveForContentTags :: FilePath -> [Identifier] -> IO (M.Map Identifier [String])
scanArchiveForContentTags _ postIdents = do
    results <- forM postIdents $ \ident -> do
        let path = toFilePath ident
        content <- readFile path
        let preprocessed = preprocessScriptaImport content
            tags = extractContentTags preprocessed
        return (ident, tags)
    return $ M.fromList results

-- | Build reverse index: tag name -> list of identifiers with that tag
buildTagIndex :: M.Map Identifier [String] -> M.Map String [Identifier]
buildTagIndex tagMap = M.foldrWithKey addTags M.empty tagMap
  where
    addTags ident tags acc = foldr (addTag ident) acc tags
    addTag ident tag acc = M.insertWith (++) tag [ident] acc

