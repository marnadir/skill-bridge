//client per la dashboard statistiche (GET /stats, autenticato)
import { authEnabled, getAccessToken, login } from '../auth/auth'

const API_BASE_URL: string | undefined = import.meta.env.VITE_API_BASE_URL

export interface DailyPoint {
  date: string
  jobs: number
  cost_eur: number
}

export interface Stats {
  window_days: number
  total_jobs: number
  completed: number
  failed: number
  needs_review: number
  processing: number
  total_cost_eur: number
  avg_cost_per_cv_eur: number
  daily: DailyPoint[]
}

//statistiche simulate per lo sviluppo senza backend
const SIMULATED: Stats = {
  window_days: 14,
  total_jobs: 12,
  completed: 9,
  failed: 1,
  needs_review: 2,
  processing: 0,
  total_cost_eur: 0.54,
  avg_cost_per_cv_eur: 0.06,
  daily: Array.from({ length: 15 }, (_, i) => ({
    date: new Date(Date.now() - (14 - i) * 86400000).toISOString().slice(0, 10),
    jobs: [0, 1, 0, 2, 1, 0, 0, 3, 1, 0, 1, 0, 2, 1, 0][i],
    cost_eur: [0, 0.06, 0, 0.12, 0.05, 0, 0, 0.18, 0.06, 0, 0.05, 0, 0.11, 0.06, 0][i],
  })),
}

export async function fetchStats(): Promise<Stats> {
  if (!API_BASE_URL) {
    await new Promise((resolve) => setTimeout(resolve, 400))
    return SIMULATED
  }

  const headers: Record<string, string> = {}
  if (authEnabled) {
    const token = await getAccessToken()
    if (!token) {
      await login()
      throw new Error('Autenticazione richiesta')
    }
    headers.authorization = `Bearer ${token}`
  }

  const response = await fetch(`${API_BASE_URL}/stats`, { headers })
  if (response.status === 401) {
    await login()
    throw new Error('Sessione scaduta')
  }
  if (!response.ok) {
    throw new Error(`Lettura statistiche fallita (HTTP ${response.status})`)
  }
  return (await response.json()) as Stats
}
