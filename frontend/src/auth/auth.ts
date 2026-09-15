//autenticazione Cognito con Authorization Code + PKCE (ADR-014).
//Nessuna dipendenza: il flusso e' ~100 righe di standard OAuth.
//Senza le env VITE_COGNITO_* l'auth e' disattivata (modalita' demo).
//La password non tocca mai questo codice: il login avviene sulla
//Hosted UI di Cognito; qui gestiamo solo redirect, code exchange e
//conservazione dei token (sessionStorage: trade-off documentato).

const DOMAIN: string | undefined = import.meta.env.VITE_COGNITO_DOMAIN
const CLIENT_ID: string | undefined = import.meta.env.VITE_COGNITO_CLIENT_ID
const REDIRECT_URI = window.location.origin

const STORAGE_KEY = 'sb.tokens'
const VERIFIER_KEY = 'sb.pkce_verifier'

interface StoredTokens {
  accessToken: string
  idToken: string
  refreshToken: string | null
  expiresAt: number //epoch ms
}

export const authEnabled = Boolean(DOMAIN && CLIENT_ID)

//--- primitive PKCE --------------------------------------------------

function randomString(length: number): string {
  const bytes = crypto.getRandomValues(new Uint8Array(length))
  return Array.from(bytes, (b) => 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[b % 62]).join('')
}

async function sha256base64url(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input))
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '')
}

//--- storage ----------------------------------------------------------

function loadTokens(): StoredTokens | null {
  const raw = sessionStorage.getItem(STORAGE_KEY)
  return raw ? (JSON.parse(raw) as StoredTokens) : null
}

function saveTokens(tokens: StoredTokens): void {
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify(tokens))
}

//--- flusso -----------------------------------------------------------

//avvia il login: genera il segreto per-login (verifier), manda a
//Cognito solo la sua impronta (challenge) e redirige alla Hosted UI
export async function login(): Promise<void> {
  const verifier = randomString(64)
  sessionStorage.setItem(VERIFIER_KEY, verifier)
  const challenge = await sha256base64url(verifier)

  const params = new URLSearchParams({
    response_type: 'code',
    client_id: CLIENT_ID!,
    redirect_uri: REDIRECT_URI,
    scope: 'openid email',
    code_challenge_method: 'S256',
    code_challenge: challenge,
  })
  window.location.assign(`${DOMAIN}/oauth2/authorize?${params}`)
}

//al ritorno dalla Hosted UI (?code=...): scambia il code + verifier
//con i token. Ritorna true se l'utente e' autenticato
export async function handleCallback(): Promise<boolean> {
  if (!authEnabled) return false

  const code = new URLSearchParams(window.location.search).get('code')
  if (!code) return isAuthenticated()

  const verifier = sessionStorage.getItem(VERIFIER_KEY)
  if (!verifier) return isAuthenticated()

  const response = await fetch(`${DOMAIN}/oauth2/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'authorization_code',
      client_id: CLIENT_ID!,
      redirect_uri: REDIRECT_URI,
      code,
      code_verifier: verifier,
    }),
  })
  //ripulisce l'URL dal code in ogni caso (finisce in history)
  window.history.replaceState({}, '', window.location.pathname)
  sessionStorage.removeItem(VERIFIER_KEY)

  if (!response.ok) return false
  const body = (await response.json()) as {
    access_token: string
    id_token: string
    refresh_token?: string
    expires_in: number
  }
  saveTokens({
    accessToken: body.access_token,
    idToken: body.id_token,
    refreshToken: body.refresh_token ?? null,
    expiresAt: Date.now() + body.expires_in * 1000,
  })
  return true
}

//token valido per le chiamate API; rinnova col refresh token se
//scaduto; null = serve il login
export async function getAccessToken(): Promise<string | null> {
  if (!authEnabled) return null
  const tokens = loadTokens()
  if (!tokens) return null
  if (Date.now() < tokens.expiresAt - 60_000) return tokens.accessToken
  if (!tokens.refreshToken) return null

  const response = await fetch(`${DOMAIN}/oauth2/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      client_id: CLIENT_ID!,
      refresh_token: tokens.refreshToken,
    }),
  })
  if (!response.ok) return null
  const body = (await response.json()) as { access_token: string; id_token: string; expires_in: number }
  saveTokens({
    ...tokens,
    accessToken: body.access_token,
    idToken: body.id_token,
    expiresAt: Date.now() + body.expires_in * 1000,
  })
  return body.access_token
}

export function isAuthenticated(): boolean {
  const tokens = loadTokens()
  return tokens !== null && (Date.now() < tokens.expiresAt || tokens.refreshToken !== null)
}

//email dell'utente loggato (dal payload dell'id token, per la UI)
export function userEmail(): string | null {
  const tokens = loadTokens()
  if (!tokens) return null
  try {
    const payload = JSON.parse(atob(tokens.idToken.split('.')[1])) as { email?: string }
    return payload.email ?? null
  } catch {
    return null
  }
}

export function logout(): void {
  sessionStorage.removeItem(STORAGE_KEY)
  if (authEnabled) {
    const params = new URLSearchParams({ client_id: CLIENT_ID!, logout_uri: REDIRECT_URI })
    window.location.assign(`${DOMAIN}/logout?${params}`)
  }
}
