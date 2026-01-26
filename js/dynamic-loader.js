// Dynamic content loader for two-column layout
// Only active on desktop (>= 800px)

(function() {
    const isDesktop = window.matchMedia('(min-width: 800px)').matches;
    if (!isDesktop) return;

    // Find the list and content elements
    const notesList = document.getElementById('notes-list');
    const postList = document.getElementById('post-list');
    const list = notesList || postList;
    if (!list) return;

    const contentColumn = document.querySelector('.content-column');
    if (!contentColumn) return;

    const placeholder = contentColumn.querySelector('.content-placeholder');
    const dynamicContent = contentColumn.querySelector('.dynamic-content');
    if (!placeholder || !dynamicContent) return;

    let currentUrl = null;

    // Handle anchor link clicks within dynamic content (event delegation)
    dynamicContent.addEventListener('click', function(e) {
        const link = e.target.closest('a[href^="#"]');
        if (!link) return;

        e.preventDefault();
        e.stopPropagation();

        const targetId = link.getAttribute('href').substring(1);
        if (!targetId) return;

        const targetElement = dynamicContent.querySelector('#' + CSS.escape(targetId));
        if (targetElement) {
            targetElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    });

    // Load content from a URL into the right pane (exposed globally)
    window.loadContent = async function loadContent(url, pushState = true) {
        try {
            const response = await fetch(url);
            if (!response.ok) throw new Error('Failed to fetch');

            const html = await response.text();
            const parser = new DOMParser();
            const doc = parser.parseFromString(html, 'text/html');

            // Extract article content - look for main content
            const main = doc.querySelector('main');
            if (!main) throw new Error('No main element found');

            // Get the content (skip the h1 title if we want to show our own)
            const title = main.querySelector('h1');
            const titleText = title ? title.textContent : '';

            // Clone the main content
            const content = main.cloneNode(true);

            // Show the dynamic content area
            placeholder.style.display = 'none';
            dynamicContent.style.display = 'block';
            dynamicContent.innerHTML = content.innerHTML;

            // Update URL without page reload
            if (pushState && url !== currentUrl) {
                history.pushState({ url: url }, '', url);
            }
            currentUrl = url;

            // Update selected state in list
            updateSelectedState(url);

            // Re-render KaTeX math if available
            if (typeof renderMathInElement === 'function') {
                renderMathInElement(dynamicContent, {
                    delimiters: [
                        {left: '$$', right: '$$', display: true},
                        {left: '$', right: '$', display: false},
                        {left: '\\[', right: '\\]', display: true},
                        {left: '\\(', right: '\\)', display: false}
                    ],
                    throwOnError: false
                });
            }

            // Scroll content column to top
            dynamicContent.scrollTop = 0;

        } catch (error) {
            console.error('Error loading content:', error);
            // On error, navigate normally
            window.location.href = url;
        }
    }

    // Update selected state in the list
    function updateSelectedState(url) {
        list.querySelectorAll('li').forEach(li => {
            const link = li.querySelector('a');
            if (link && link.dataset.absoluteUrl === url) {
                li.classList.add('selected');
            } else {
                li.classList.remove('selected');
            }
        });
    }

    // Store absolute URLs on page load before pushState changes anything
    list.querySelectorAll('li a').forEach(link => {
        link.dataset.absoluteUrl = new URL(link.href).pathname;
    });

    // Intercept clicks on list items
    list.addEventListener('click', function(e) {
        // Find the clicked link or li
        const li = e.target.closest('li');
        if (!li) return;

        const link = li.querySelector('a');
        if (!link) return;

        // Use pre-stored absolute URL
        const url = link.dataset.absoluteUrl;
        if (!url) return;

        // Prevent default navigation
        e.preventDefault();

        // Load content dynamically
        window.loadContent(url);
    });

    // Handle browser back/forward navigation
    window.addEventListener('popstate', function(e) {
        if (e.state && e.state.url) {
            loadContent(e.state.url, false);
        } else {
            // If no state, we're back at the list page
            placeholder.style.display = 'block';
            dynamicContent.style.display = 'none';
            dynamicContent.innerHTML = '';
            currentUrl = null;
            updateSelectedState(null);
        }
    });

    // Check if we should load initial content from URL
    // This handles direct navigation to a note/post URL
    const path = window.location.pathname;
    const isListPage = path === '/notes/' || path === '/notes/index.html' ||
                       path === '/blog.html' || path === '/blog' ||
                       path === '/diary/' || path === '/diary/index.html' ||
                       path === '/memoirs/' || path === '/memoirs/index.html' ||
                       path === '/drafts/' || path === '/drafts/index.html';

    if (!isListPage) {
        // We're on an individual page, don't intercept
        return;
    }

    // Store initial state
    history.replaceState({ url: window.location.pathname }, '', window.location.pathname);

    // Fix nav links to use absolute URLs (prevents issues after pushState)
    document.querySelectorAll('nav a').forEach(link => {
        const absoluteUrl = new URL(link.href).pathname;
        link.setAttribute('href', absoluteUrl);
    });

    // Auto-select first visible item on page load
    function selectFirstVisible() {
        const listId = notesList ? 'notes-list' : 'post-list';
        const firstVisible = document.querySelector('#' + listId + ' li:not([style*="display: none"])');
        if (firstVisible) {
            const link = firstVisible.querySelector('a');
            if (link && link.dataset.absoluteUrl) {
                window.loadContent(link.dataset.absoluteUrl);
            }
        }
    }

    // Expose for use by filter/search functions
    window.selectFirstVisible = selectFirstVisible;

    // Select first item on initial load (deferred to ensure DOM is ready)
    setTimeout(selectFirstVisible, 100);
})();
