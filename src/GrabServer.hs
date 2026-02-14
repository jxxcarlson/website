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
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import GHC.Generics (Generic)
import qualified Data.Text.Lazy as TL
import Control.Monad.IO.Class (liftIO)
import System.Directory (getHomeDirectory, getCurrentDirectory)
import System.FilePath ((</>))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import Data.IORef
import System.Process (createProcess, proc, terminateProcess, interruptProcessGroupOf, getProcessExitCode, ProcessHandle, CreateProcess(..))
import Control.Exception (try, SomeException)

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

-- | Dashboard process management state
data ServerState = ServerState
    { devServerProc :: Maybe ProcessHandle
    , watchProc     :: Maybe ProcessHandle
    }

-- | JSON-serializable process status
data ProcessInfo = ProcessInfo
    { devServerRunning :: Bool
    , watchRunning     :: Bool
    , lastDeploy       :: Maybe String
    } deriving (Show, Generic)

instance ToJSON ProcessInfo

-- | Check if a ProcessHandle is still running
isRunning :: Maybe ProcessHandle -> IO Bool
isRunning Nothing = return False
isRunning (Just ph) = do
    ec <- getProcessExitCode ph
    return $ case ec of
        Nothing -> True   -- still running
        Just _  -> False  -- exited

-- | Read last deploy time from /tmp/archive_watcher_lastdeploy
getLastDeploy :: IO (Maybe String)
getLastDeploy = do
    result <- try (readFile "/tmp/archive_watcher_lastdeploy") :: IO (Either SomeException String)
    case result of
        Left _  -> return Nothing
        Right s -> return (Just (take 20 s))

-- | Start dev server: kill port 8000, rebuild site, then start site watch
startDevServer :: IORef ServerState -> IO (Either String String)
startDevServer ref = do
    st <- readIORef ref
    running <- isRunning (devServerProc st)
    if running
        then return (Left "Dev server is already running")
        else do
            cwd <- getCurrentDirectory
            -- Kill old server, build, rebuild, then exec into site watch.
            -- 'exec' replaces the shell so our ProcessHandle tracks the
            -- long-running site watch process directly.
            let cmd = "lsof -ti:8000 | xargs kill -9 2>/dev/null; sleep 1; "
                   ++ "ulimit -n 10240; "
                   ++ "stack build && stack exec site rebuild && exec stack exec site watch"
                cp = (proc "sh" ["-c", cmd])
                    { cwd = Just cwd
                    , create_group = True
                    }
            (_, _, _, ph) <- createProcess cp
            writeIORef ref st { devServerProc = Just ph }
            return (Right "Dev server started")

-- | Stop dev server: kill process group + kill port 8000
stopDevServer :: IORef ServerState -> IO (Either String String)
stopDevServer ref = do
    st <- readIORef ref
    case devServerProc st of
        Nothing -> return (Left "Dev server is not running")
        Just ph -> do
            interruptProcessGroupOf ph
            _ <- createProcess (proc "sh" ["-c", "lsof -ti:8000 | xargs kill -9 2>/dev/null"])
            writeIORef ref st { devServerProc = Nothing }
            return (Right "Dev server stopped")

-- | Start watch: runs "sh scripts/watch_and_deploy.sh"
startWatch :: IORef ServerState -> IO (Either String String)
startWatch ref = do
    st <- readIORef ref
    running <- isRunning (watchProc st)
    if running
        then return (Left "Watch process is already running")
        else do
            cwd <- getCurrentDirectory
            let cp = (proc "sh" [cwd </> "scripts" </> "watch_and_deploy.sh"])
                    { cwd = Just cwd
                    , create_group = True
                    }
            (_, _, _, ph) <- createProcess cp
            writeIORef ref st { watchProc = Just ph }
            return (Right "Watch process started")

-- | Stop watch: kill process group (includes fswatch children)
stopWatch :: IORef ServerState -> IO (Either String String)
stopWatch ref = do
    st <- readIORef ref
    case watchProc st of
        Nothing -> return (Left "Watch process is not running")
        Just ph -> do
            interruptProcessGroupOf ph
            writeIORef ref st { watchProc = Nothing }
            return (Right "Watch process stopped")

-- | Deploy: runs "sh scripts/deploy.sh"
runDeploy :: IO (Either String String)
runDeploy = do
    cwd <- getCurrentDirectory
    let cp = (proc "sh" [cwd </> "scripts" </> "deploy.sh"])
            { cwd = Just cwd
            }
    _ <- createProcess cp
    return (Right "Deploy started")

main :: IO ()
main = do
    putStrLn "Grab server starting on port 8080..."
    stateRef <- newIORef (ServerState Nothing Nothing)
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

        -- Dashboard: process status
        get "/api/status" $ do
            st <- liftIO $ readIORef stateRef
            devRunning <- liftIO $ isRunning (devServerProc st)
            wRunning <- liftIO $ isRunning (watchProc st)
            deploy <- liftIO getLastDeploy
            json $ ProcessInfo devRunning wRunning deploy

        -- Dashboard: start dev server
        post "/api/start-dev" $ do
            result <- liftIO $ startDevServer stateRef
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard: stop dev server
        post "/api/stop-dev" $ do
            result <- liftIO $ stopDevServer stateRef
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard: start watch process
        post "/api/start-watch" $ do
            result <- liftIO $ startWatch stateRef
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard: stop watch process
        post "/api/stop-watch" $ do
            result <- liftIO $ stopWatch stateRef
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard: run deploy
        post "/api/deploy" $ do
            result <- liftIO runDeploy
            case result of
                Left err  -> json $ object ["status" .= ("error" :: String), "message" .= err]
                Right msg -> json $ object ["status" .= ("ok" :: String), "message" .= msg]

        -- Dashboard HTML page
        get "/dashboard" $ do
            setHeader "Content-Type" "text/html; charset=utf-8"
            html dashboardHtml

-- | Dashboard HTML served inline
dashboardHtml :: TL.Text
dashboardHtml = TL.pack $ unlines
    [ "<!DOCTYPE html>"
    , "<html lang=\"en\">"
    , "<head>"
    , "<meta charset=\"UTF-8\">"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">"
    , "<title>Site Dashboard</title>"
    , "<style>"
    , "  * { margin: 0; padding: 0; box-sizing: border-box; }"
    , "  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;"
    , "         background: #1a1a2e; color: #e0e0e0; padding: 2rem; }"
    , "  h1 { text-align: center; margin-bottom: 2rem; color: #e94560; font-size: 1.5rem; }"
    , "  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));"
    , "          gap: 1.5rem; max-width: 900px; margin: 0 auto; }"
    , "  .card { background: #16213e; border-radius: 12px; padding: 1.5rem;"
    , "          border: 1px solid #0f3460; }"
    , "  .card h2 { font-size: 1rem; margin-bottom: 1rem; color: #e94560; }"
    , "  .status-row { display: flex; align-items: center; gap: 0.75rem; margin-bottom: 1rem; }"
    , "  .dot { width: 12px; height: 12px; border-radius: 50%; flex-shrink: 0; }"
    , "  .dot.on  { background: #4ecca3; box-shadow: 0 0 8px #4ecca3; }"
    , "  .dot.off { background: #e94560; box-shadow: 0 0 8px #e94560; }"
    , "  .status-label { font-size: 0.9rem; color: #a0a0b0; }"
    , "  button { padding: 0.5rem 1.25rem; border: none; border-radius: 6px; cursor: pointer;"
    , "           font-size: 0.85rem; font-weight: 600; transition: opacity 0.2s; }"
    , "  button:hover { opacity: 0.85; }"
    , "  button:disabled { opacity: 0.4; cursor: not-allowed; }"
    , "  .btn-start { background: #4ecca3; color: #1a1a2e; }"
    , "  .btn-stop  { background: #e94560; color: #fff; }"
    , "  .btn-deploy { background: #0f3460; color: #e0e0e0; border: 1px solid #e94560; }"
    , "  .deploy-info { font-size: 0.8rem; color: #a0a0b0; margin-top: 0.75rem; }"
    , "  .msg { font-size: 0.8rem; color: #a0a0b0; margin-top: 0.5rem; min-height: 1.2em; }"
    , "</style>"
    , "</head>"
    , "<body>"
    , "<h1>Site Dashboard</h1>"
    , "<div class=\"grid\">"
    , ""
    , "  <div class=\"card\">"
    , "    <h2>Dev Server</h2>"
    , "    <div class=\"status-row\">"
    , "      <div id=\"dev-dot\" class=\"dot off\"></div>"
    , "      <span id=\"dev-label\" class=\"status-label\">Stopped</span>"
    , "    </div>"
    , "    <button id=\"dev-start\" class=\"btn-start\" onclick=\"postAction('/api/start-dev', 'dev-msg')\">Start</button>"
    , "    <button id=\"dev-stop\" class=\"btn-stop\" onclick=\"postAction('/api/stop-dev', 'dev-msg')\">Stop</button>"
    , "    <div id=\"dev-msg\" class=\"msg\"></div>"
    , "  </div>"
    , ""
    , "  <div class=\"card\">"
    , "    <h2>Watch &amp; Deploy</h2>"
    , "    <div class=\"status-row\">"
    , "      <div id=\"watch-dot\" class=\"dot off\"></div>"
    , "      <span id=\"watch-label\" class=\"status-label\">Stopped</span>"
    , "    </div>"
    , "    <button id=\"watch-start\" class=\"btn-start\" onclick=\"postAction('/api/start-watch', 'watch-msg')\">Start</button>"
    , "    <button id=\"watch-stop\" class=\"btn-stop\" onclick=\"postAction('/api/stop-watch', 'watch-msg')\">Stop</button>"
    , "    <div id=\"watch-msg\" class=\"msg\"></div>"
    , "  </div>"
    , ""
    , "  <div class=\"card\">"
    , "    <h2>Deploy</h2>"
    , "    <button class=\"btn-deploy\" onclick=\"postAction('/api/deploy', 'deploy-msg')\">Deploy Now</button>"
    , "    <div id=\"deploy-msg\" class=\"msg\"></div>"
    , "    <div id=\"last-deploy\" class=\"deploy-info\"></div>"
    , "  </div>"
    , ""
    , "</div>"
    , ""
    , "<script>"
    , "function updateStatus() {"
    , "  fetch('/api/status')"
    , "    .then(r => r.json())"
    , "    .then(d => {"
    , "      setDot('dev', d.devServerRunning);"
    , "      setDot('watch', d.watchRunning);"
    , "      const el = document.getElementById('last-deploy');"
    , "      if (d.lastDeploy) {"
    , "        const ts = parseInt(d.lastDeploy);"
    , "        if (!isNaN(ts)) {"
    , "          el.textContent = 'Last deploy: ' + new Date(ts * 1000).toLocaleString();"
    , "        } else {"
    , "          el.textContent = 'Last deploy: ' + d.lastDeploy;"
    , "        }"
    , "      } else {"
    , "        el.textContent = 'No deploy info';"
    , "      }"
    , "    })"
    , "    .catch(() => {});"
    , "}"
    , ""
    , "function setDot(prefix, running) {"
    , "  const dot = document.getElementById(prefix + '-dot');"
    , "  const label = document.getElementById(prefix + '-label');"
    , "  dot.className = running ? 'dot on' : 'dot off';"
    , "  label.textContent = running ? 'Running' : 'Stopped';"
    , "}"
    , ""
    , "function postAction(url, msgId) {"
    , "  const el = document.getElementById(msgId);"
    , "  el.textContent = 'Working...';"
    , "  fetch(url, { method: 'POST' })"
    , "    .then(r => r.json())"
    , "    .then(d => {"
    , "      el.textContent = d.message || d.status;"
    , "      setTimeout(updateStatus, 1000);"
    , "    })"
    , "    .catch(e => { el.textContent = 'Error: ' + e.message; });"
    , "}"
    , ""
    , "updateStatus();"
    , "setInterval(updateStatus, 5000);"
    , "</script>"
    , "</body>"
    , "</html>"
    ]

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
