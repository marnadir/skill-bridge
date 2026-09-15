//client verso il backend-api (API Gateway): POST /jobs crea il job e
//restituisce la presigned URL, la PUT carica il CV direttamente su
//S3. Senza VITE_API_BASE_URL il flusso viene simulato per lo
//sviluppo senza backend
import { authEnabled, getAccessToken, login } from '../auth/auth'

const API_BASE_URL: string | undefined = import.meta.env.VITE_API_BASE_URL

//header di autenticazione: il gateway valida il token PRIMA della
//lambda; senza token valido si viene rimandati al login
async function authHeaders(): Promise<Record<string, string>> {
  if (!authEnabled) return {}
  const token = await getAccessToken()
  if (!token) {
    await login() //redirect: non si torna da qui
    throw new Error('Autenticazione richiesta')
  }
  return { authorization: `Bearer ${token}` }
}

export interface UploadResult {
  fileName: string
  jobId: string
  simulated: boolean
}

interface CreateJobResponse {
  jobId: string
  uploadUrl: string
  expiresIn: number
}

export async function uploadCv(file: File): Promise<UploadResult> {
  if (!API_BASE_URL) {
    //nessun backend configurato: simula la latenza di rete
    await new Promise((resolve) => setTimeout(resolve, 800))
    return { fileName: file.name, jobId: 'simulated', simulated: true }
  }

  //1) crea il job: il backend traccia lo stato e firma l'upload
  const createResponse = await fetch(`${API_BASE_URL}/jobs`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(await authHeaders()) },
    body: JSON.stringify({
      fileName: file.name,
      contentType: file.type,
      size: file.size,
    }),
  })

  if (createResponse.status === 401) {
    await login() //token scaduto/revocato: si rifa' il giro
    throw new Error('Sessione scaduta')
  }
  if (!createResponse.ok) {
    const detail = await createResponse
      .json()
      .then((b: { message?: string }) => b.message)
      .catch(() => undefined)
    throw new Error(detail ?? `Creazione job fallita (HTTP ${createResponse.status})`)
  }

  const { jobId, uploadUrl } = (await createResponse.json()) as CreateJobResponse

  //2) carica il file direttamente su S3 col presigned URL
  const uploadResponse = await fetch(uploadUrl, {
    method: 'PUT',
    headers: { 'content-type': file.type },
    body: file,
  })

  if (!uploadResponse.ok) {
    throw new Error(`Upload su S3 fallito (HTTP ${uploadResponse.status})`)
  }

  return { fileName: file.name, jobId, simulated: false }
}
