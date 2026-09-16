import type { EmployerCheck, JdMatch, MatchReport } from '../api/cv'
import './MatchResults.css'

//badge di esito: icona + testo, mai solo colore (colori di stato
//riservati: verde=match, ambra=da verificare, grigio=no)
const OUTCOME_BADGE: Record<JdMatch['outcome'], { label: string; icon: string; cls: string }> = {
  match: { label: 'Match', icon: '✓', cls: 'match' },
  not_verifiable: { label: 'Da verificare', icon: '?', cls: 'review' },
  no_match: { label: 'Non in linea', icon: '—', cls: 'no' },
}

const EMPLOYER_BADGE: Record<EmployerCheck['outcome'], { label: string; icon: string; cls: string }> = {
  verified: { label: 'Verificato', icon: '✓', cls: 'match' },
  not_found: { label: 'Non trovato', icon: '✕', cls: 'no' },
  not_verifiable: { label: 'Non verificabile', icon: '?', cls: 'review' },
}

function MatchCard({ match }: { match: JdMatch }) {
  const badge = OUTCOME_BADGE[match.outcome]
  return (
    <div className="results__card">
      <div className="results__card-head">
        <strong>{match.title}</strong>
        <span className={`results__badge results__badge--${badge.cls}`}>
          {badge.icon} {badge.label} · {(match.score * 100).toFixed(0)}%
        </span>
      </div>
      {match.evidences.length > 0 && (
        <ul className="results__evidences">
          {match.evidences.map((evidence) => (
            <li key={evidence}>{evidence}</li>
          ))}
        </ul>
      )}
    </div>
  )
}

export function MatchResults({ report }: { report: MatchReport }) {
  const sorted = [...report.matches].sort((a, b) => b.score - a.score)
  const relevant = sorted.filter((m) => m.outcome !== 'no_match')
  const noMatches = sorted.filter((m) => m.outcome === 'no_match')

  return (
    <div className="results">
      <h2 className="results__title">Posizioni in linea con il profilo</h2>

      {relevant.length === 0 && (
        <p className="results__empty">Nessuna posizione in linea trovata per questo profilo.</p>
      )}
      {relevant.map((match) => (
        <MatchCard key={match.jd_id} match={match} />
      ))}

      {noMatches.length > 0 && (
        <details className="results__nomatch">
          <summary>
            Altre {noMatches.length} posizioni valutate: non in linea
          </summary>
          {noMatches.map((match) => (
            <MatchCard key={match.jd_id} match={match} />
          ))}
        </details>
      )}

      {report.employer_checks.length > 0 && (
        <>
          <h3 className="results__subtitle">Verifica datori di lavoro dichiarati</h3>
          <ul className="results__employers">
            {report.employer_checks.map((check) => {
              const badge = EMPLOYER_BADGE[check.outcome]
              return (
                <li key={check.employer}>
                  <span>{check.employer}</span>
                  <span className={`results__badge results__badge--${badge.cls}`}>
                    {badge.icon} {badge.label}
                  </span>
                </li>
              )
            })}
          </ul>
        </>
      )}

      <p className="results__disclaimer">
        Il sistema propone, il recruiter decide: gli esiti vanno validati.
      </p>
    </div>
  )
}
