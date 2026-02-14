# Grab Feature Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a "Grab" feature that fetches a web page by URL, strips noise, and converts it to clean Scripta or Markdown markup for download.

**Architecture:** A separate Haskell executable (`grab-server`) in the same project, using Scotty on port 8080. Shares `src/` modules with the Hakyll site. The static site gets a `/grab.html` page with a JS-driven UI that calls the Scotty endpoint.

**Tech Stack:** Haskell (Scotty, http-conduit, tagsoup, aeson), JavaScript (fetch API, Blob download)

---

### Task 1: Update package.yaml with grab-server executable and dependencies

**Files:**
- Modify: `package.yaml`

**Step 1: Add new dependencies and executable**

Add `scotty`, `http-conduit`, `tagsoup`, `aeson`, `bytestring`, `wai`, `wai-cors`, and `time` to the dependency list. Add a second executable `grab-server` block.

The modified `package.yaml` should be:

```yaml
name: website
version: 0.1.0.0
synopsis: Personal website built with Hakyll
license: BSD-3-Clause
author: Author
maintainer: author@example.com

dependencies:
  - base >= 4.14 && < 5
  - hakyll >= 4.15 && < 5
  - pandoc
  - text
  - containers
  - directory
  - filepath
  - unix

executables:
  site:
    main: Site.hs
    source-dirs: src
    other-modules:
      - Scripta
      - Utils
      - Archive
    ghc-options:
      - -threaded

  grab-server:
    main: GrabServer.hs
    source-dirs: src
    other-modules:
      - Grab
    dependencies:
      - scotty
      - http-conduit
      - tagsoup
      - aeson
      - bytestring
      - wai
      - wai-cors
      - time
    ghc-options:
      - -threaded
```

**Step 2: Verify it parses**

Run: `cd /Users/carlson/dev/website/Website && stack build --dry-run 2>&1 | head -20`

Expected: Dependency resolution output (may download new packages). No parse errors.

**Step 3: Commit**

```bash
git add package.yaml
git commit -m "feat: add grab-server executable and dependencies to package.yaml"
```

---

### Task 2: Create Grab.hs — URL fetching and HTML parsing

**Files:**
- Create: `src/Grab.hs`

**Step 1: Create the module with types and fetchURL**

```haskell
{-# LANGUAGE OverloadedStrings #-}

module Grab
    ( grabURL
    , GrabResult(..)
    , OutputFormat(..)
    ) where

import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BL8
import Network.HTTP.Simple
import Text.HTML.TagSoup
import Data.Char (isSpace, toLower, isAlphaNum)
import Data.List (isPrefixOf, isInfixOf)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)

data OutputFormat = Markdown | Scripta deriving (Eq, Show)

data GrabResult = GrabResult
    { grabTitle    :: String
    , grabContent  :: String
    , grabFilename :: String
    } deriving (Show)

-- | Fetch a URL and convert its content to the requested format
grabURL :: String -> OutputFormat -> IO (Either String GrabResult)
grabURL url format = do
    result <- fetchHTML url
    case result of
        Left err -> return (Left err)
        Right html -> do
            let tags = parseTags html
                title = extractTitle tags
                cleaned = cleanTags tags
                content = convertTags format cleaned
                doc = renderDocument format title content
            filename <- generateFilename title format
            return $ Right $ GrabResult title doc filename

-- | Fetch HTML from a URL, returning the body as a String
fetchHTML :: String -> IO (Either String String)
fetchHTML url = do
    req <- parseRequest url
    let req' = setRequestHeader "User-Agent"
               ["Mozilla/5.0 (compatible; GrabBot/1.0)"] req
    response <- httpLBS req'
    let status = getResponseStatusCode response
    if status >= 200 && status < 400
        then return $ Right $ BL8.unpack $ getResponseBody response
        else return $ Left $ "HTTP error: " ++ show status

-- | Generate a filename from the title and timestamp
generateFilename :: String -> OutputFormat -> IO String
generateFilename title format = do
    now <- getCurrentTime
    let timestamp = formatTime defaultTimeLocale "%Y%m%d%H%M%S" now
        slug = take 40 $ map slugChar $ filter isValidChar title
        ext = case format of
                Markdown -> ".md"
                Scripta  -> ".scripta"
    return $ "grab-" ++ timestamp ++ "-" ++ slug ++ ext
  where
    isValidChar c = isAlphaNum c || c == ' ' || c == '-'
    slugChar ' ' = '-'
    slugChar c   = toLower c
```

**Step 2: Build to check for compile errors**

Run: `cd /Users/carlson/dev/website/Website && stack build grab-server 2>&1 | tail -20`

Expected: Will fail because module is incomplete (missing functions). That's OK for now — we just want to verify the imports and types parse.

**Step 3: Commit**

```bash
git add src/Grab.hs
git commit -m "feat: add Grab module with URL fetching and types"
```

---

### Task 3: Add HTML cleaning functions to Grab.hs

**Files:**
- Modify: `src/Grab.hs`

**Step 1: Add extractTitle and cleanTags functions**

Append these functions to `src/Grab.hs`:

```haskell
-- | Extract the page title from HTML tags
-- Tries: <title>, <meta og:title>, first <h1>
extractTitle :: [Tag String] -> String
extractTitle tags =
    case findTitle tags of
        Just t  -> trim t
        Nothing -> case findOgTitle tags of
            Just t  -> trim t
            Nothing -> case findFirstH1 tags of
                Just t  -> trim t
                Nothing -> "Untitled"

findTitle :: [Tag String] -> Maybe String
findTitle [] = Nothing
findTitle (TagOpen "title" _ : TagText t : _) = Just t
findTitle (_:rest) = findTitle rest

findOgTitle :: [Tag String] -> Maybe String
findOgTitle [] = Nothing
findOgTitle (TagOpen "meta" attrs : rest)
    | lookupAttr "property" attrs == Just "og:title" = lookupAttr "content" attrs
    | otherwise = findOgTitle rest
findOgTitle (_:rest) = findOgTitle rest

findFirstH1 :: [Tag String] -> Maybe String
findFirstH1 [] = Nothing
findFirstH1 (TagOpen "h1" _ : TagText t : _) = Just t
findFirstH1 (_:rest) = findFirstH1 rest

lookupAttr :: String -> [Attribute String] -> Maybe String
lookupAttr key attrs = lookup key attrs

-- | Remove unwanted elements from the tag list
-- Strips: script, style, nav, footer, aside, iframe, noscript, svg, form, button, input
-- Also strips elements with ad-related class/id names
cleanTags :: [Tag String] -> [Tag String]
cleanTags = extractMainContent . stripUnwanted

-- | Strip all unwanted element types (script, style, nav, etc.)
stripUnwanted :: [Tag String] -> [Tag String]
stripUnwanted [] = []
stripUnwanted (tag@(TagOpen name _) : rest)
    | map toLower name `elem` unwantedTags =
        stripUnwanted (dropUntilClose name rest)
    | isAdElement tag =
        stripUnwanted (dropUntilClose name rest)
    | otherwise = tag : stripUnwanted rest
stripUnwanted (tag : rest) = tag : stripUnwanted rest

unwantedTags :: [String]
unwantedTags = ["script", "style", "nav", "footer", "aside", "iframe",
                "noscript", "svg", "form", "button", "input", "header"]

-- | Check if an element looks like an ad or tracking element
isAdElement :: Tag String -> Bool
isAdElement (TagOpen _ attrs) =
    let classVal = map toLower $ maybe "" id (lookupAttr "class" attrs)
        idVal    = map toLower $ maybe "" id (lookupAttr "id" attrs)
        adWords  = ["ad-", "ads-", "advert", "banner", "social-share",
                     "share-", "tracking", "cookie", "popup", "modal",
                     "sidebar", "widget", "newsletter", "subscribe"]
    in any (`isInfixOf` classVal) adWords || any (`isInfixOf` idVal) adWords
isAdElement _ = False

-- | Drop tags until the closing tag for the given element name
-- Handles nesting of same-named elements
dropUntilClose :: String -> [Tag String] -> [Tag String]
dropUntilClose name = go 1
  where
    go 0 rest = rest
    go _ [] = []
    go depth (TagOpen n _ : rest)
        | map toLower n == map toLower name = go (depth + 1) rest
    go depth (TagClose n : rest)
        | map toLower n == map toLower name = go (depth - 1) rest
    go depth (_ : rest) = go depth rest

-- | Try to extract the main content area (<article>, <main>, or <body>)
extractMainContent :: [Tag String] -> [Tag String]
extractMainContent tags =
    case findSection "article" tags of
        Just content -> content
        Nothing -> case findSection "main" tags of
            Just content -> content
            Nothing -> case findSection "body" tags of
                Just content -> content
                Nothing -> tags  -- fallback: use everything

-- | Find the content between <name> and </name>
findSection :: String -> [Tag String] -> Maybe [Tag String]
findSection _ [] = Nothing
findSection name (TagOpen n _ : rest)
    | map toLower n == name = Just (takeUntilClose name rest)
findSection name (_ : rest) = findSection name rest

-- | Take tags until the closing tag (handling nesting)
takeUntilClose :: String -> [Tag String] -> [Tag String]
takeUntilClose name = go 0
  where
    go _ [] = []
    go depth (TagOpen n attrs : rest)
        | map toLower n == name = TagOpen n attrs : go (depth + 1) rest
    go 0 (TagClose n : _)
        | map toLower n == name = []
    go depth (TagClose n : rest)
        | map toLower n == name = TagClose n : go (depth - 1) rest
    go depth (tag : rest) = tag : go depth rest

-- | Trim whitespace from both ends
trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse
```

**Step 2: Build to check**

Run: `cd /Users/carlson/dev/website/Website && stack build grab-server 2>&1 | tail -20`

Expected: Still won't compile (missing `convertTags`, `renderDocument`), but no errors in the new functions.

**Step 3: Commit**

```bash
git add src/Grab.hs
git commit -m "feat: add HTML cleaning and title extraction to Grab"
```

---

### Task 4: Add content conversion functions to Grab.hs

**Files:**
- Modify: `src/Grab.hs`

**Step 1: Add convertTags and renderDocument**

Append these functions to `src/Grab.hs`:

```haskell
-- | Convert cleaned HTML tags to the target format
convertTags :: OutputFormat -> [Tag String] -> String
convertTags format = go False
  where
    go _ [] = ""
    go inPre (TagOpen name attrs : rest)
        | lname == "h1" = heading format 1 rest
        | lname == "h2" = heading format 2 rest
        | lname == "h3" = heading format 3 rest
        | lname == "h4" = heading format 4 rest
        | lname == "h5" = heading format 5 rest
        | lname == "h6" = heading format 6 rest
        | lname == "p"  = "\n" ++ go inPre rest
        | lname == "br" = "\n" ++ go inPre rest
        | lname == "hr" = "\n---\n" ++ go inPre rest
        | lname == "img" = renderImg format attrs ++ go inPre rest
        | lname == "a" = renderLinkOpen format attrs ++ go inPre rest
        | lname == "strong" || lname == "b" = boldOpen format ++ go inPre rest
        | lname == "em" || lname == "i" = italicOpen format ++ go inPre rest
        | lname == "u" = underlineOpen format ++ go inPre rest
        | lname == "pre" = "\n```\n" ++ go True rest
        | lname == "code" && not inPre = "`" ++ go inPre rest
        | lname == "blockquote" = "\n> " ++ go inPre rest
        | lname == "li" = "\n- " ++ go inPre rest
        | lname == "ul" || lname == "ol" = "\n" ++ go inPre rest
        | lname == "div" || lname == "section" || lname == "span"
          || lname == "table" || lname == "tr" || lname == "td"
          || lname == "th" || lname == "thead" || lname == "tbody"
          || lname == "figure" || lname == "figcaption" = go inPre rest
        | otherwise = go inPre rest
      where lname = map toLower name
    go inPre (TagClose name : rest)
        | lname == "p"  = "\n" ++ go inPre rest
        | lname == "a"  = renderLinkClose format ++ go inPre rest
        | lname == "strong" || lname == "b" = boldClose format ++ go inPre rest
        | lname == "em" || lname == "i" = italicClose format ++ go inPre rest
        | lname == "u" = underlineClose format ++ go inPre rest
        | lname == "pre" = "\n```\n" ++ go False rest
        | lname == "code" && not inPre = "`" ++ go inPre rest
        | lname == "blockquote" = "\n" ++ go inPre rest
        | lname == "div" || lname == "li" = "\n" ++ go inPre rest
        | otherwise = go inPre rest
      where lname = map toLower name
    go inPre (TagText text : rest) =
        let cleaned = if inPre then text else collapseWhitespace text
        in cleaned ++ go inPre rest
    go inPre (_ : rest) = go inPre rest

    -- Extract heading text and render with appropriate prefix
    heading fmt level tags =
        let (textTags, remaining) = break isHeadingClose tags
            text = extractText textTags
            prefix = replicate level '#'
            remaining' = drop 1 remaining  -- drop the closing tag
        in "\n" ++ prefix ++ " " ++ trim text ++ "\n" ++ go False remaining'

    isHeadingClose (TagClose n) = map toLower n `elem` ["h1","h2","h3","h4","h5","h6"]
    isHeadingClose _ = False

-- | Extract plain text from a list of tags
extractText :: [Tag String] -> String
extractText = concatMap getText
  where
    getText (TagText t) = t
    getText _ = ""

-- | Collapse whitespace in text (multiple spaces/newlines -> single space)
collapseWhitespace :: String -> String
collapseWhitespace = go False
  where
    go _ [] = ""
    go True (c:cs)
        | isSpace c = go True cs
        | otherwise = c : go False cs
    go False (c:cs)
        | isSpace c = ' ' : go True cs
        | otherwise = c : go False cs

-- | Render an image tag
renderImg :: OutputFormat -> [Attribute String] -> String
renderImg Markdown attrs =
    let src = maybe "" id (lookupAttr "src" attrs)
        alt = maybe "" id (lookupAttr "alt" attrs)
    in if null src then ""
       else "\n![" ++ alt ++ "](" ++ src ++ ")\n"
renderImg Scripta attrs =
    let src = maybe "" id (lookupAttr "src" attrs)
    in if null src then ""
       else "\n| image\n" ++ src ++ "\n"

-- | Link handling — we accumulate link text between open and close
-- For simplicity, we store the href and emit it on close
-- This requires a small state trick: we embed the URL in the output
-- and fix it up when we see the close tag.
renderLinkOpen :: OutputFormat -> [Attribute String] -> String
renderLinkOpen Markdown attrs =
    let href = maybe "" id (lookupAttr "href" attrs)
    in "[" ++ "{LINK_URL:" ++ href ++ "}"
renderLinkOpen Scripta attrs =
    let href = maybe "" id (lookupAttr "href" attrs)
    in "[link " ++ "{LINK_URL:" ++ href ++ "}"

renderLinkClose :: OutputFormat -> String
renderLinkClose Markdown = "]"
renderLinkClose Scripta = "]"

-- | Bold markup
boldOpen :: OutputFormat -> String
boldOpen Markdown = "**"
boldOpen Scripta = "[b "

boldClose :: OutputFormat -> String
boldClose Markdown = "**"
boldClose Scripta = "]"

-- | Italic markup
italicOpen :: OutputFormat -> String
italicOpen Markdown = "*"
italicOpen Scripta = "[i "

italicClose :: OutputFormat -> String
italicClose Markdown = "*"
italicClose Scripta = "]"

-- | Underline markup
underlineOpen :: OutputFormat -> String
underlineOpen Markdown = "<u>"
underlineOpen Scripta = "[u "

underlineClose :: OutputFormat -> String
underlineClose Markdown = "</u>"
underlineClose Scripta = "]"

-- | Post-process the converted text to fix up link references
-- Replaces "[{LINK_URL:http://...}Link Text]" with proper format
fixupLinks :: OutputFormat -> String -> String
fixupLinks Markdown = fixupMarkdownLinks
fixupLinks Scripta = fixupScriptaLinks

fixupMarkdownLinks :: String -> String
fixupMarkdownLinks [] = []
fixupMarkdownLinks ('[':'{':'L':'I':'N':'K':'_':'U':'R':'L':':':rest) =
    let (url, afterUrl) = break (== '}') rest
        afterBrace = drop 1 afterUrl  -- drop '}'
        (text, afterBracket) = break (== ']') afterBrace
        afterClose = drop 1 afterBracket  -- drop ']'
    in "[" ++ text ++ "](" ++ url ++ ")" ++ fixupMarkdownLinks afterClose
fixupMarkdownLinks (c:cs) = c : fixupMarkdownLinks cs

fixupScriptaLinks :: String -> String
fixupScriptaLinks [] = []
fixupScriptaLinks ('[':'l':'i':'n':'k':' ':'{':'L':'I':'N':'K':'_':'U':'R':'L':':':rest) =
    let (url, afterUrl) = break (== '}') rest
        afterBrace = drop 1 afterUrl  -- drop '}'
        (text, afterBracket) = break (== ']') afterBrace
        afterClose = drop 1 afterBracket  -- drop ']'
    in "[link " ++ trim text ++ " " ++ url ++ "]" ++ fixupScriptaLinks afterClose
fixupScriptaLinks (c:cs) = c : fixupScriptaLinks cs

-- | Assemble the final document with title at top
renderDocument :: OutputFormat -> String -> String -> String
renderDocument format title content =
    let fixed = fixupLinks format content
        -- Clean up excessive blank lines (3+ newlines -> 2)
        cleaned = collapseBlankLines fixed
    in "# " ++ title ++ "\n\n" ++ cleaned

-- | Collapse runs of 3+ newlines down to 2
collapseBlankLines :: String -> String
collapseBlankLines [] = []
collapseBlankLines ('\n':'\n':'\n':rest) = '\n' : '\n' : collapseBlankLines (dropWhile (== '\n') rest)
collapseBlankLines (c:cs) = c : collapseBlankLines cs
```

**Step 2: Build**

Run: `cd /Users/carlson/dev/website/Website && stack build grab-server 2>&1 | tail -20`

Expected: Compiles successfully. If there are warnings, fix them.

**Step 3: Commit**

```bash
git add src/Grab.hs
git commit -m "feat: add HTML-to-Markdown/Scripta conversion in Grab"
```

---

### Task 5: Create GrabServer.hs — Scotty endpoint

**Files:**
- Create: `src/GrabServer.hs`

**Step 1: Write the Scotty server**

```haskell
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

import Web.Scotty
import Network.Wai.Middleware.Cors
import Data.Aeson (FromJSON, ToJSON, object, (.=))
import GHC.Generics (Generic)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE

import Grab (grabURL, GrabResult(..), OutputFormat(..))

data GrabRequest = GrabRequest
    { url    :: String
    , format :: String
    } deriving (Show, Generic)

instance FromJSON GrabRequest

main :: IO ()
main = do
    putStrLn "Grab server starting on port 8080..."
    scotty 8080 $ do
        middleware $ cors $ const $ Just CorsResourcePolicy
            { corsOrigins = Nothing  -- allow all origins
            , corsMethods = ["GET", "POST", "OPTIONS"]
            , corsRequestHeaders = ["Content-Type"]
            , corsExposedHeaders = Nothing
            , corsMaxAge = Just 3600
            , corsVaryOrigin = False
            , corsRequireOrigin = False
            , corsIgnoreFailures = False
            }

        post "/api/grab" $ do
            req <- jsonData :: ActionM GrabRequest
            let fmt = case format req of
                    "scripta" -> Scripta
                    _         -> Markdown
            result <- liftIO $ grabURL (url req) fmt
            case result of
                Left err -> do
                    status status400
                    json $ object ["error" .= (err :: String)]
                Right gr -> do
                    setHeader "Content-Type" "text/plain; charset=utf-8"
                    setHeader "X-Filename" (TL.pack $ grabFilename gr)
                    text (TL.pack $ grabContent gr)

        get "/api/health" $ do
            text "ok"
```

**Step 2: Build**

Run: `cd /Users/carlson/dev/website/Website && stack build grab-server 2>&1 | tail -20`

Expected: Compiles successfully.

**Step 3: Quick smoke test**

Run: `cd /Users/carlson/dev/website/Website && stack exec grab-server &`

Then in another terminal:
```bash
curl -s -X POST http://localhost:8080/api/grab \
  -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","format":"md"}' | head -5
```

Expected: Should return markdown content starting with `# Example Domain`

Stop the server: `kill %1`

**Step 4: Commit**

```bash
git add src/GrabServer.hs
git commit -m "feat: add Scotty-based grab server endpoint"
```

---

### Task 6: Add Grab nav link and page to the Hakyll site

**Files:**
- Modify: `templates/default.html:22` (add nav link after Home)
- Create: `content/pages/grab.md`
- Create: `js/grab.js`

**Step 1: Add nav link to default.html**

After the line `<a href="/">Home</a>`, add:
```html
            <a href="/grab.html">Grab</a>
```

**Step 2: Create the Grab page content**

Create `content/pages/grab.md`:

```markdown
---
title: Grab
---

<div id="grab-app">
    <div class="grab-form">
        <input type="text" id="grab-url" placeholder="Enter URL to grab..." class="grab-input">
        <div class="grab-options">
            <label><input type="radio" name="grab-format" value="md" checked> Markdown</label>
            <label><input type="radio" name="grab-format" value="scripta"> Scripta</label>
        </div>
        <button id="grab-btn" class="grab-button" onclick="doGrab()">Grab</button>
    </div>
    <div id="grab-status" class="grab-status"></div>
    <div id="grab-preview" class="grab-preview"></div>
</div>

<script src="/js/grab.js"></script>
```

**Step 3: Create grab.js**

Create `js/grab.js`:

```javascript
function doGrab() {
    var urlInput = document.getElementById('grab-url');
    var statusDiv = document.getElementById('grab-status');
    var previewDiv = document.getElementById('grab-preview');
    var btn = document.getElementById('grab-btn');
    var url = urlInput.value.trim();

    if (!url) {
        statusDiv.textContent = 'Please enter a URL.';
        statusDiv.className = 'grab-status grab-error';
        return;
    }

    // Add protocol if missing
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://' + url;
    }

    var format = document.querySelector('input[name="grab-format"]:checked').value;

    btn.disabled = true;
    btn.textContent = 'Grabbing...';
    statusDiv.textContent = 'Fetching and converting...';
    statusDiv.className = 'grab-status';
    previewDiv.textContent = '';

    fetch('http://localhost:8080/api/grab', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url, format: format })
    })
    .then(function(response) {
        if (!response.ok) {
            return response.json().then(function(data) {
                throw new Error(data.error || 'Server error');
            });
        }
        var filename = response.headers.get('X-Filename') || 'grabbed-document.' + format;
        return response.text().then(function(text) {
            return { text: text, filename: filename };
        });
    })
    .then(function(result) {
        statusDiv.textContent = 'Done! Downloading ' + result.filename;
        statusDiv.className = 'grab-status grab-success';

        // Show preview (first 500 chars)
        previewDiv.textContent = result.text.substring(0, 500) + (result.text.length > 500 ? '\n...' : '');

        // Trigger download
        var blob = new Blob([result.text], { type: 'text/plain' });
        var a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = result.filename;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        URL.revokeObjectURL(a.href);
    })
    .catch(function(err) {
        statusDiv.textContent = 'Error: ' + err.message;
        statusDiv.className = 'grab-status grab-error';
        previewDiv.textContent = '';
    })
    .finally(function() {
        btn.disabled = false;
        btn.textContent = 'Grab';
    });
}

// Allow pressing Enter in the URL field
document.addEventListener('DOMContentLoaded', function() {
    var input = document.getElementById('grab-url');
    if (input) {
        input.addEventListener('keypress', function(e) {
            if (e.key === 'Enter') doGrab();
        });
    }
});
```

**Step 4: Add CSS for the grab page**

Append to `css/default.css`:

```css
/* Grab page */
.grab-form {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5em;
    align-items: center;
    margin-bottom: 1em;
}
.grab-input {
    flex: 1;
    min-width: 300px;
    padding: 0.5em;
    font-size: 1em;
    border: 1px solid #ccc;
    border-radius: 4px;
}
.grab-options {
    display: flex;
    gap: 1em;
}
.grab-options label {
    cursor: pointer;
}
.grab-button {
    padding: 0.5em 1.5em;
    font-size: 1em;
    background: #333;
    color: white;
    border: none;
    border-radius: 4px;
    cursor: pointer;
}
.grab-button:hover {
    background: #555;
}
.grab-button:disabled {
    background: #999;
    cursor: not-allowed;
}
.grab-status {
    margin: 0.5em 0;
    padding: 0.5em;
    min-height: 1.5em;
}
.grab-error {
    color: #c00;
}
.grab-success {
    color: #060;
}
.grab-preview {
    background: #f0f0f0;
    padding: 1em;
    border-radius: 4px;
    white-space: pre-wrap;
    font-family: monospace;
    font-size: 0.85em;
    max-height: 400px;
    overflow-y: auto;
    display: none;
}
.grab-preview:not(:empty) {
    display: block;
}
```

**Step 5: Build the site**

Run: `cd /Users/carlson/dev/website/Website && stack build && stack exec site rebuild 2>&1 | tail -10`

Expected: Site builds, `/grab.html` appears in `_site/`.

**Step 6: Commit**

```bash
git add templates/default.html content/pages/grab.md js/grab.js css/default.css
git commit -m "feat: add Grab page UI with nav link, JS client, and CSS"
```

---

### Task 7: Integration test — end-to-end verification

**Files:** None (manual testing)

**Step 1: Start the grab server**

Run: `cd /Users/carlson/dev/website/Website && stack exec grab-server &`

**Step 2: Start the Hakyll dev server**

Run: `cd /Users/carlson/dev/website/Website && stack exec site watch`

**Step 3: Test in browser**

1. Open `http://localhost:8000/grab.html`
2. Verify the Grab link appears in the nav bar
3. Enter `https://example.com` in the text field
4. Select "Markdown" format
5. Click "Grab"
6. Verify: a file downloads with content starting with `# Example Domain`
7. Switch to "Scripta" format, click Grab again
8. Verify: a `.scripta` file downloads with `[link ...]` style links

**Step 4: Test with a real article**

Try a Wikipedia article or news article URL. Verify:
- Title extracted correctly
- Headings have proper `##` / `###` prefixes
- Images converted to `| image\nURL` (Scripta) or `![alt](URL)` (Markdown)
- Links converted properly
- No script/style/nav content in output
- Ads and social share buttons removed

**Step 5: Fix any issues found during testing**

If conversion quality is poor for certain sites, adjust the cleaning heuristics in `Grab.hs`.

**Step 6: Final commit if any fixes were needed**

```bash
git add -A
git commit -m "fix: polish Grab conversion based on integration testing"
```

---

## Summary of files

| File | Action | Purpose |
|------|--------|---------|
| `package.yaml` | Modify | Add grab-server executable + deps |
| `src/Grab.hs` | Create | HTML fetch, clean, convert logic |
| `src/GrabServer.hs` | Create | Scotty server on port 8080 |
| `templates/default.html` | Modify | Add "Grab" nav link |
| `content/pages/grab.md` | Create | Grab page with form UI |
| `js/grab.js` | Create | Client-side fetch + download |
| `css/default.css` | Modify | Grab page styling |
