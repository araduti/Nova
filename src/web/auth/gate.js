/**
 * Nova Auth Gate — shared Entra ID authentication module.
 *
 * Drop-in script for any Nova web page to enforce Microsoft Entra ID
 * sign-in before revealing content.
 *
 * Prerequisites:
 *   1. The page <body> must have class "auth-pending".
 *   2. msal-browser.min.js must be loaded BEFORE this script.
 *   3. login.css must be linked in the <head>.
 *   4. config/auth.json must be accessible at /config/auth.json.
 *
 * After successful authentication the script:
 *   - Removes the "auth-pending" class so content becomes visible.
 *   - Dispatches a "nova:authenticated" CustomEvent on document with
 *     { detail: { account } }.
 *
 * If auth.json sets requireAuth = false (or is unreachable), the gate
 * reveals content immediately without sign-in.
 */
(function novaAuthGate() {
    'use strict';

    /* ── 1. Inject login overlay ──────────────────────────────────── */
    var overlay = document.createElement('div');
    overlay.id = 'novaLoginOverlay';
    overlay.className = 'login-overlay';
    overlay.innerHTML =
        '<div class="login-card">' +
            '<div class="login-logo"><span class="logo-icon">&#9729;</span> Nova</div>' +
            '<h2>Sign in required</h2>' +
            '<p>You must sign in with your Microsoft 365 account to continue.</p>' +
            '<hr class="login-divider">' +
            '<button id="novaLoginBtn" class="login-btn hidden">' +
                '<svg width="18" height="18" viewBox="0 0 21 21" fill="none">' +
                    '<rect x="1" y="1" width="9" height="9" fill="#f25022"/>' +
                    '<rect x="11" y="1" width="9" height="9" fill="#7fba00"/>' +
                    '<rect x="1" y="11" width="9" height="9" fill="#00a4ef"/>' +
                    '<rect x="11" y="11" width="9" height="9" fill="#ffb900"/>' +
                '</svg>' +
                ' Sign in with Microsoft' +
            '</button>' +
            '<p id="novaLoginError" class="login-error hidden"></p>' +
            '<p id="novaLoginLoading" class="login-loading" role="status">' +
                '<span class="login-spinner" aria-hidden="true"></span> Checking authentication\u2026' +
            '</p>' +
        '</div>';
    document.body.prepend(overlay);

    /* ── 2. Helpers ───────────────────────────────────────────────── */
    function reveal(account) {
        overlay.remove();
        document.body.classList.remove('auth-pending');
        document.dispatchEvent(new CustomEvent('nova:authenticated', { detail: { account: account } }));
    }

    function showLoginBtn() {
        document.getElementById('novaLoginLoading').classList.add('hidden');
        document.getElementById('novaLoginBtn').classList.remove('hidden');
    }

    function showError(msg) {
        document.getElementById('novaLoginLoading').classList.add('hidden');
        document.getElementById('novaLoginBtn').classList.add('hidden');
        var el = document.getElementById('novaLoginError');
        el.textContent = msg;
        el.classList.remove('hidden');
    }

    /* ── 3. Resolve config path (works from any page depth) ───────── */
    var base = document.querySelector('base');
    var configUrl = (base ? base.href : '') + '/config/auth.json';
    /* Normalise double-slashes that may arise when base is missing */
    configUrl = configUrl.replace(/([^:])\/\//g, '$1/');
    /* If the page is at the repo root, the relative path is fine */
    if (configUrl.charAt(0) !== '/' && configUrl.indexOf('://') === -1) {
        configUrl = '/' + configUrl;
    }

    /* ── 4. Fetch config & initialise MSAL ────────────────────────── */
    fetch('/config/auth.json')
        .then(function (r) { if (!r.ok) throw new Error(r.statusText); return r.json(); })
        .then(function (config) {
            if (!config.requireAuth || !config.clientId) {
                reveal(null);
                return;
            }

            if (typeof msal === 'undefined') {
                showError('Authentication library failed to load. Check your network, ad-blocker, or corporate network restrictions.');
                return;
            }

            var msalConfig = {
                auth: {
                    clientId: config.clientId,
                    authority: 'https://login.microsoftonline.com/organizations',
                    redirectUri: config.redirectUri || (window.location.origin + window.location.pathname)
                },
                cache: { cacheLocation: 'sessionStorage' }
            };

            var app = new msal.PublicClientApplication(msalConfig);

            app.initialize().then(function () {
                return app.handleRedirectPromise();
            }).then(function (response) {
                if (response && response.account) {
                    app.setActiveAccount(response.account);
                    reveal(response.account);
                    return;
                }

                /* Check for existing session (e.g. authenticated on another page). */
                var accounts = app.getAllAccounts();
                if (accounts.length > 0) {
                    app.setActiveAccount(accounts[0]);
                    reveal(accounts[0]);
                    return;
                }

                showLoginBtn();
            }).catch(function () {
                showLoginBtn();
            });

            document.getElementById('novaLoginBtn').addEventListener('click', function () {
                document.getElementById('novaLoginError').classList.add('hidden');
                app.loginRedirect({ scopes: ['openid', 'profile'] });
            });
        })
        .catch(function () {
            /* Config unreachable — reveal without auth */
            reveal(null);
        });
})();
