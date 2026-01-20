#!/bin/bash

# Kill any process running on port 8000 (Hakyll watch server)
lsof -ti:8000 | xargs kill -9 2>/dev/null
sleep 1

stack build
stack exec site rebuild
stack exec site watch
