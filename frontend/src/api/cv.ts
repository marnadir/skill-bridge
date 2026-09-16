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

export type JobStatus = 'PENDING_UPLOAD' | 'PROCESSING' | 'COMPLETED' | 'FAILED' | 'NEEDS_REVIEW'

export interface JdMatch {
  jd_id: string
  title: string
  outcome: 'match' | 'no_match' | 'not_verifiable'
  score: number
  evidences: string[]
}

export interface EmployerCheck {
  employer: string
  outcome: 'verified' | 'not_found' | 'not_verifiable'
}

export interface MatchReport {
  matches: JdMatch[]
  employer_checks: EmployerCheck[]
}

export interface Job {
  jobId: string
  status: JobStatus
  fileName: string
  error?: string
  results?: MatchReport
}

//riga della lista GET /jobs (senza il report, che pesa: il
//dettaglio arriva da GET /jobs/{jobId} all'apertura della card)
export interface JobSummary {
  jobId: string
  status: JobStatus
  fileName: string
  createdAt: string
  updatedAt: string
}

//report simulato per lo sviluppo senza backend
const SIMULATED_REPORT: MatchReport = {
  matches: [
    { jd_id: 'jd-003', title: 'GenAI Solutions Engineer', outcome: 'match', score: 0.92,
      evidences: ['Due anni su soluzioni GenAI scalabili', 'Piattaforma RAG centralizzata per il prototyping'] },
    { jd_id: 'jd-001', title: 'Senior Data Engineer', outcome: 'match', score: 0.85,
      evidences: ['Pipeline ETL con Spark e Airflow su AWS'] },
    { jd_id: 'jd-007', title: 'BI / Analytics Engineer', outcome: 'not_verifiable', score: 0.4, evidences: [] },
    { jd_id: 'jd-004', title: 'Frontend Engineer (React)', outcome: 'no_match', score: 0.1, evidences: [] },
  ],
  employer_checks: [
    { employer: 'Machine Learning Reply', outcome: 'verified' },
    { employer: 'Ditta Sconosciuta', outcome: 'not_found' },
  ],
}

//storico simulato per lo sviluppo senza backend
const SIMULATED_JOBS: JobSummary[] = [
  { jobId: 'sim-1', status: 'COMPLETED', fileName: 'cv_mario_rossi.pdf',
    createdAt: '2026-09-15T10:12:00Z', updatedAt: '2026-09-15T10:14:00Z' },
  { jobId: 'sim-2', status: 'NEEDS_REVIEW', fileName: 'cv_scansione.pdf',
    createdAt: '2026-09-14T16:40:00Z', updatedAt: '2026-09-14T16:41:00Z' },
  { jobId: 'sim-3', status: 'FAILED', fileName: 'cv_corrotto.pdf',
    createdAt: '2026-09-13T09:05:00Z', updatedAt: '2026-09-13T09:06:00Z' },
  { jobId: 'sim-4', status: 'PROCESSING', fileName: 'cv_in_lavorazione.pdf',
    createdAt: '2026-09-16T08:00:00Z', updatedAt: '2026-09-16T08:00:30Z' },
]

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

//stato puntuale di un job (usata dal polling e dal dettaglio in
///results)
export async function fetchJob(jobId: string): Promise<Job> {
  if (!API_BASE_URL) {
    await new Promise((resolve) => setTimeout(resolve, 400))
    const summary = SIMULATED_JOBS.find((j) => j.jobId === jobId)
    return {
      jobId,
      status: summary?.status ?? 'COMPLETED',
      fileName: summary?.fileName ?? 'simulato.pdf',
      ...(summary?.status === 'FAILED' ? { error: 'Errore simulato del parsing' } : {}),
      ...(!summary || summary.status === 'COMPLETED' ? { results: SIMULATED_REPORT } : {}),
    }
  }

  const response = await fetch(`${API_BASE_URL}/jobs/${encodeURIComponent(jobId)}`, {
    headers: await authHeaders(),
  })
  if (response.status === 401) {
    await login()
    throw new Error('Sessione scaduta')
  }
  if (!response.ok) {
    throw new Error(`Lettura stato job fallita (HTTP ${response.status})`)
  }
  return (await response.json()) as Job
}

//elenco dei CV caricati dall'utente (pagina /results), dal piu'
//recente: il backend filtra per created_by ricavato dal JWT
export async function fetchJobs(): Promise<JobSummary[]> {
  if (!API_BASE_URL) {
    await new Promise((resolve) => setTimeout(resolve, 400))
    return [...SIMULATED_JOBS].sort((a, b) => b.createdAt.localeCompare(a.createdAt))
  }

  const response = await fetch(`${API_BASE_URL}/jobs`, { headers: await authHeaders() })
  if (response.status === 401) {
    await login()
    throw new Error('Sessione scaduta')
  }
  if (!response.ok) {
    throw new Error(`Lettura elenco job fallita (HTTP ${response.status})`)
  }
  return ((await response.json()) as { jobs: JobSummary[] }).jobs
}

//attende che il documento torni visibile: il polling si sospende
//quando la tab e' in background (niente richieste sprecate)
async function waitVisible(): Promise<void> {
  while (document.hidden) {
    await new Promise((resolve) => setTimeout(resolve, 1000))
  }
}

//polling dello stato del job fino a uno stato terminale.
//Intervallo 20s (scelta esplicita: ~6-7 poll per job), timeout duro,
//pausa a tab nascosta. Ritorna null se il timeout scade prima
export async function waitForJob(
  jobId: string,
  onStatus?: (status: JobStatus) => void,
  { intervalMs = 20000, timeoutMs = 360000 } = {},
): Promise<Job | null> {
  if (!API_BASE_URL) {
    onStatus?.('PROCESSING')
    await new Promise((resolve) => setTimeout(resolve, 2000))
    return { jobId, status: 'COMPLETED', fileName: 'simulato.pdf', results: SIMULATED_REPORT }
  }

  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    await waitVisible()
    const job = await fetchJob(jobId)
    onStatus?.(job.status)
    if (job.status === 'COMPLETED' || job.status === 'FAILED' || job.status === 'NEEDS_REVIEW') {
      return job
    }

    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }

  return null
}
