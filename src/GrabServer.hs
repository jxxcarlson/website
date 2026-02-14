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

import Grab (grabURL, GrabResult(..), OutputFormat(..))

-- | JSON request body for /api/grab
data GrabRequest = GrabRequest
    { url    :: String
    , format :: String
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
                    result <- liftIO $ grabURL (url req) fmt
                    case result of
                        Left err -> do
                            status status400
                            json $ object ["error" .= err]
                        Right grabResult -> do
                            setHeader "Content-Type" "text/plain; charset=utf-8"
                            setHeader "X-Filename" (TL.pack $ grabFilename grabResult)
                            text (TL.pack $ grabContent grabResult)

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
