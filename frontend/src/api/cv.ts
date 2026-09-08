//client verso il backend di skill-bridge: chiede alla lambda un
//presigned URL e carica il CV direttamente su S3. Finche'
//VITE_API_BASE_URL (function url della lambda) non e' valorizzata
//l'upload viene solo simulato
const API_BASE_URL: string | undefined = import.meta.env.VITE_API_BASE_URL

export interface UploadResult {
  fileName: string
  simulated: boolean
}

interface PresignResponse {
  uploadUrl: string
  key: string
  expiresIn: number
}

export async function uploadCv(file: File): Promise<UploadResult> {
  if (!API_BASE_URL) {
    //nessun backend configurato: simula la latenza di rete
    await new Promise((resolve) => setTimeout(resolve, 800))
    return { fileName: file.name, simulated: true }
  }

  //1) chiede il presigned URL alla lambda
  const presignResponse = await fetch(API_BASE_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      fileName: file.name,
      contentType: file.type,
      size: file.size,
    }),
  })

  if (!presignResponse.ok) {
    const detail = await presignResponse
      .json()
      .then((b: { message?: string }) => b.message)
      .catch(() => undefined)
    throw new Error(detail ?? `Richiesta presigned URL fallita (HTTP ${presignResponse.status})`)
  }

  const { uploadUrl } = (await presignResponse.json()) as PresignResponse

  //2) carica il file direttamente su S3 col presigned URL
  const uploadResponse = await fetch(uploadUrl, {
    method: 'PUT',
    headers: { 'content-type': file.type },
    body: file,
  })

  if (!uploadResponse.ok) {
    throw new Error(`Upload su S3 fallito (HTTP ${uploadResponse.status})`)
  }

  return { fileName: file.name, simulated: false }
}
