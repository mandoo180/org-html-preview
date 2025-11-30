/**
 * org-html-preview live reload script
 * Connects to WebSocket server and reloads page on updates
 */
(function() {
    'use strict';

    // wsPort is injected by the HTML template
    if (typeof window.ORG_PREVIEW_WS_PORT === 'undefined') {
        console.error('org-html-preview: WebSocket port not defined');
        return;
    }

    const wsPort = window.ORG_PREVIEW_WS_PORT;
    const statusEl = document.getElementById('ws-status');

    let ws;
    let reconnectAttempts = 0;
    const maxReconnectAttempts = 10;
    const reconnectDelay = 2000;
    let statusTimeout;

    function showStatus(connected) {
        if (!statusEl) return;

        statusEl.className = connected ? 'connected' : 'disconnected';
        statusEl.textContent = connected ? 'Connected' : 'Disconnected';
        statusEl.classList.remove('hidden');

        clearTimeout(statusTimeout);
        if (connected) {
            statusTimeout = setTimeout(function() {
                statusEl.classList.add('hidden');
            }, 2000);
        }
    }

    function connect() {
        try {
            ws = new WebSocket('ws://localhost:' + wsPort);

            ws.onopen = function() {
                console.log('org-html-preview: WebSocket connected');
                reconnectAttempts = 0;
                showStatus(true);
            };

            ws.onmessage = function(event) {
                try {
                    const data = JSON.parse(event.data);
                    if (data.type === 'reload') {
                        console.log('org-html-preview: Reload signal received');
                        location.reload();
                    }
                } catch (e) {
                    console.error('org-html-preview: Failed to parse message', e);
                }
            };

            ws.onclose = function() {
                console.log('org-html-preview: WebSocket disconnected');
                showStatus(false);
                attemptReconnect();
            };

            ws.onerror = function(error) {
                console.error('org-html-preview: WebSocket error', error);
            };
        } catch (e) {
            console.error('org-html-preview: WebSocket connection failed', e);
            attemptReconnect();
        }
    }

    function attemptReconnect() {
        if (reconnectAttempts < maxReconnectAttempts) {
            reconnectAttempts++;
            console.log('org-html-preview: Reconnecting... (' + reconnectAttempts + '/' + maxReconnectAttempts + ')');
            setTimeout(connect, reconnectDelay);
        } else {
            console.log('org-html-preview: Max reconnection attempts reached');
        }
    }

    // Start connection when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', connect);
    } else {
        connect();
    }
})();
