import { useEffect, useState } from 'react'
import { fetchJob, fetchJobs } from '../api/cv'
import type { Job, JobStatus, JobSummary } from '../api/cv'
import { MatchResults } from './MatchResults'
import './ResultsList.css'

type ListState =
  | { kind: 'loading' }
  | { kind: 'ready'; jobs: JobSummary[] }
  | { kind: 'error'; message: string }

type Detail = { kind: 'loading' } | { kind: 'ready'; job: Job } | { kind: 'error'; message: string }

//badge di stato del job: icona + testo, mai solo colore
const STATUS_BADGE: Record<JobStatus, { label: string; icon: string; cls: string }> = {
  COMPLETED: { label: 'Completato', icon: '✓', cls: 'ok' },
  NEEDS_REVIEW: { label: 'Da rivedere', icon: '?', cls: 'review' },
  FAILED: { label: 'Fallito', icon: '✕', cls: 'fail' },
  PROCESSING: { label: 'In lavorazione', icon: '⟳', cls: 'progress' },
  PENDING_UPLOAD: { label: 'In attesa del file', icon: '…', cls: 'progress' },
}

function formatDate(iso: string): string {
  return new Date(iso).toLocaleString('it-IT', { dateStyle: 'medium', timeStyle: 'short' })
}

function JobDetail({ detail }: { detail: Detail }) {
  if (detail.kind === 'loading') return <p className="jobs__note">Caricamento risultati…</p>
  if (detail.kind === 'error') return <p className="jobs__note">Errore: {detail.message}</p>

  const { job } = detail
  if (job.status === 'COMPLETED' && job.results) return <MatchResults report={job.results} />
  if (job.status === 'NEEDS_REVIEW') {
    return (
      <p className="jobs__note">
        Il documento non ha superato i controlli automatici ed è in coda di revisione umana.
      </p>
    )
  }
  if (job.status === 'FAILED') {
    return <p className="jobs__note">Elaborazione fallita{job.error ? `: ${job.error}` : '.'}</p>
  }
  return <p className="jobs__note">Elaborazione ancora in corso: i risultati non sono pronti.</p>
}

//pagina /results: elenco dei CV caricati dall'utente; il report si
//apre espandendo la card (il dettaglio viene chiesto solo allora)
export function ResultsList({ active }: { active: boolean }) {
  const [state, setState] = useState<ListState>({ kind: 'loading' })
  const [details, setDetails] = useState<Record<string, Detail>>({})

  //la pagina resta montata (App tiene vive le viste): si ricarica
  //l'elenco a ogni ingresso nella pagina, non solo al mount; i dati
  //precedenti restano visibili durante il refresh
  useEffect(() => {
    if (!active) return
    fetchJobs()
      .then((jobs) => {
        setDetails({})
        setState({ kind: 'ready', jobs })
      })
      .catch((err: Error) => setState({ kind: 'error', message: err.message }))
  }, [active])

  const openDetail = (jobId: string) => {
    if (details[jobId]) return //gia' caricato o in caricamento
    setDetails((d) => ({ ...d, [jobId]: { kind: 'loading' } }))
    fetchJob(jobId)
      .then((job) => setDetails((d) => ({ ...d, [jobId]: { kind: 'ready', job } })))
      .catch((err: Error) =>
        setDetails((d) => ({ ...d, [jobId]: { kind: 'error', message: err.message } })),
      )
  }

  if (state.kind === 'loading') return <p className="jobs__note">Caricamento elenco…</p>
  if (state.kind === 'error') return <p className="jobs__note">Errore: {state.message}</p>

  if (state.jobs.length === 0) {
    return <p className="jobs__note">Nessun CV caricato finora: inizia dalla pagina Carica CV.</p>
  }

  return (
    <section className="jobs">
      {state.jobs.map((job) => {
        const badge = STATUS_BADGE[job.status]
        return (
          <details
            key={job.jobId}
            className="jobs__card"
            onToggle={(e) => {
              if ((e.target as HTMLDetailsElement).open) openDetail(job.jobId)
            }}
          >
            <summary className="jobs__summary">
              <span className="jobs__file">{job.fileName}</span>
              <span className="jobs__meta">
                <span className="jobs__date">{formatDate(job.createdAt)}</span>
                <span className={`jobs__badge jobs__badge--${badge.cls}`}>
                  {badge.icon} {badge.label}
                </span>
              </span>
            </summary>
            <div className="jobs__detail">
              {details[job.jobId] && <JobDetail detail={details[job.jobId]} />}
            </div>
          </details>
        )
      })}
    </section>
  )
}
