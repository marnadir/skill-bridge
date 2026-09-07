//client verso il backend di skill-bridge; l'endpoint reale (API Gateway)
//arrivera' dall'infra terraform — finche' VITE_API_BASE_URL non e'
//valorizzata l'upload viene solo simulato
const API_BASE_URL: string | undefined = import.meta.env.VITE_API_BASE_URL

export interface UploadResult {
  fileName: string
  simulated: boolean
}

export async function uploadCv(file: File): Promise<UploadResult> {
  if (!API_BASE_URL) {
    //nessun backend configurato: simula la latenza di rete
    await new Promise((resolve) => setTimeout(resolve, 800))
    return { fileName: file.name, simulated: true }
  }

  const formData = new FormData()
  formData.append('cv', file)

  const response = await fetch(`${API_BASE_URL}/cv`, {
    method: 'POST',
    body: formData,
  })

  if (!response.ok) {
    throw new Error(`Upload fallito (HTTP ${response.status})`)
  }

  return { fileName: file.name, simulated: false }
}
