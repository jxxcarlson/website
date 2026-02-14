{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

module Main where

import Web.Scotty
import Network.Wai (Middleware)
import Network.Wai.Middleware.Cors
    ( cors
    , CorsResourcePolicy(..)
    , simpleCorsResourcePolicy
    , simpleHeaders
    )
import Network.HTTP.Types.Status (status400)
import Network.HTTP.Types.Method (methodGet, methodPost, methodOptions)
import Data.Aeson (FromJSON, object, (.=))
import GHC.Generics (Generic)
import qualified Data.Text.Lazy as TL
import Control.Monad.IO.Class (liftIO)
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)

import Grab (grabURL, GrabResult(..), OutputFormat(..))

-- | JSON request body for /api/grab
data GrabRequest = GrabRequest
    { url    :: String
    , format :: String
    , tags   :: Maybe String
    } deriving (Show, Generic)

instance FromJSON GrabRequest

-- | Parse the format string into an OutputFormat
parseFormat :: String -> Maybe OutputFormat
parseFormat "md"      = Just Markdown
parseFormat "scripta" = Just Scripta
parseFormat _         = Nothing

main :: IO ()
main = do
    putStrLn "Grab server starting on port 8080..."
    scotty 8080 $ do
        middleware corsMiddleware

        -- Health check
        get "/api/health" $ do
            text "ok"

        -- Grab endpoint
        post "/api/grab" $ do
            req <- jsonData :: ActionM GrabRequest
            case parseFormat (format req) of
                Nothing -> do
                    status status400
                    json $ object ["error" .= ("Invalid format. Use 'md' or 'scripta'." :: String)]
                Just fmt -> do
                    result <- liftIO $ grabURL (url req) fmt (tags req)
                    case result of
                        Left err -> do
                            status status400
                            json $ object ["error" .= err]
                        Right grabResult -> do
                            setHeader "Content-Type" "text/plain; charset=utf-8"
                            setHeader "X-Filename" (TL.pack $ grabFilename grabResult)
                            text (TL.pack $ grabContent grabResult)

        -- Grab and save directly to The Archive
        post "/api/grab-to-archive" $ do
            req <- jsonData :: ActionM GrabRequest
            let fmt = Scripta  -- Archive notes use Scripta format
            result <- liftIO $ grabURL (url req) fmt (tags req)
            case result of
                Left err -> do
                    status status400
                    json $ object ["error" .= err]
                Right grabResult -> do
                    saveResult <- liftIO $ saveToArchive (grabTitle grabResult) (grabContent grabResult)
                    case saveResult of
                        Left err -> do
                            status status400
                            json $ object ["error" .= err]
                        Right filename -> do
                            json $ object ["filename" .= filename, "title" .= grabTitle grabResult]

-- | Save content to ~/Dropbox/theARCHIVE with a Zettelkasten ID filename
saveToArchive :: String -> String -> IO (Either String String)
saveToArchive title content = do
    home <- getHomeDirectory
    let archiveDir = home </> "Dropbox" </> "theARCHIVE"
    now <- getCurrentTime
    let zettelId = formatTime defaultTimeLocale "%Y%m%d%H%M%S" now
        filename = zettelId ++ "-" ++ sanitizeTitle title ++ ".txt"
        filepath = archiveDir </> filename
    writeFile filepath (title ++ "\n\n" ++ content)
    return $ Right filename

-- | Sanitize title for use in filename
sanitizeTitle :: String -> String
sanitizeTitle = take 40 . map dashify . filter isValid
  where
    isValid c = c `elem` (['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ " -")
    dashify ' ' = '-'
    dashify c   = c

-- | CORS middleware allowing all origins
corsMiddleware :: Middleware
corsMiddleware = cors $ const $ Just policy
  where
    policy = simpleCorsResourcePolicy
        { corsOrigins = Nothing  -- Allow all origins
        , corsMethods = [methodGet, methodPost, methodOptions]
        , corsRequestHeaders = simpleHeaders ++ ["Content-Type"]
        , corsExposedHeaders = Just ["X-Filename"]
        }
