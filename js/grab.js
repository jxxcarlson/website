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
    var tags = document.getElementById('grab-tags').value.trim();

    btn.disabled = true;
    btn.textContent = 'Grabbing...';
    statusDiv.textContent = 'Fetching and converting...';
    statusDiv.className = 'grab-status';
    previewDiv.textContent = '';

    fetch('http://localhost:8080/api/grab', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url, format: format, tags: tags || null })
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

function doGrabToArchive() {
    var urlInput = document.getElementById('grab-url');
    var statusDiv = document.getElementById('grab-status');
    var previewDiv = document.getElementById('grab-preview');
    var btn = document.getElementById('archive-btn');
    var url = urlInput.value.trim();

    if (!url) {
        statusDiv.textContent = 'Please enter a URL.';
        statusDiv.className = 'grab-status grab-error';
        return;
    }

    if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://' + url;
    }

    var tags = document.getElementById('grab-tags').value.trim();

    btn.disabled = true;
    btn.textContent = 'Saving...';
    statusDiv.textContent = 'Fetching and saving to Archive...';
    statusDiv.className = 'grab-status';
    previewDiv.textContent = '';

    fetch('http://localhost:8080/api/grab-to-archive', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: url, format: 'scripta', tags: tags || null })
    })
    .then(function(response) {
        if (!response.ok) {
            return response.json().then(function(data) {
                throw new Error(data.error || 'Server error');
            });
        }
        return response.json();
    })
    .then(function(result) {
        statusDiv.textContent = 'Saved to Archive: ' + result.filename;
        statusDiv.className = 'grab-status grab-success';
    })
    .catch(function(err) {
        statusDiv.textContent = 'Error: ' + err.message;
        statusDiv.className = 'grab-status grab-error';
    })
    .finally(function() {
        btn.disabled = false;
        btn.textContent = 'Save to Archive';
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
