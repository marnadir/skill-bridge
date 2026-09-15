import { useEffect, useState } from 'react'
import { fetchStats } from '../api/stats'
import type { Stats } from '../api/stats'
import './StatsDashboard.css'

type State =
  | { kind: 'loading' }
  | { kind: 'ready'; stats: Stats }
  | { kind: 'error'; message: string }

//bar chart a serie singola: un solo colore (accent), niente legenda
//(il titolo nomina la serie), tooltip per barra, tabella di fallback
function BarChart({
  title,
  points,
  format,
}: {
  title: string
  points: { date: string; value: number }[]
  format: (v: number) => string
}) {
  const max = Math.max(...points.map((p) => p.value), 1e-9)
  return (
    <div className="stats__chart">
      <h3 className="stats__chart-title">{title}</h3>
      <div className="stats__bars" role="img" aria-label={title}>
        {points.map((p) => (
          <div key={p.date} className="stats__bar-slot" title={`${p.date}: ${format(p.value)}`}>
            <div
              className="stats__bar"
              style={{ height: `${Math.max((p.value / max) * 100, p.value > 0 ? 4 : 0)}%` }}
            />
          </div>
        ))}
      </div>
      <div className="stats__axis">
        <span>{points[0]?.date.slice(5)}</span>
        <span>{points[points.length - 1]?.date.slice(5)}</span>
      </div>
      <details className="stats__table">
        <summary>Dati in tabella</summary>
        <table>
          <thead>
            <tr><th>Giorno</th><th>{title}</th></tr>
          </thead>
          <tbody>
            {points.filter((p) => p.value > 0).map((p) => (
              <tr key={p.date}><td>{p.date}</td><td>{format(p.value)}</td></tr>
            ))}
          </tbody>
        </table>
      </details>
    </div>
  )
}

export function StatsDashboard() {
  const [state, setState] = useState<State>({ kind: 'loading' })

  useEffect(() => {
    fetchStats()
      .then((stats) => setState({ kind: 'ready', stats }))
      .catch((err: Error) => setState({ kind: 'error', message: err.message }))
  }, [])

  if (state.kind === 'loading') {
    return <p className="stats__note">Caricamento statistiche…</p>
  }
  if (state.kind === 'error') {
    return <p className="stats__note">Errore: {state.message}</p>
  }

  const { stats } = state
  const euro = (v: number) => `€ ${v.toFixed(v >= 1 ? 2 : 3)}`

  return (
    <section className="stats">
      <p className="stats__note">Ultimi {stats.window_days} giorni</p>

      <div className="stats__tiles">
        <div className="stats__tile">
          <span className="stats__tile-value">{stats.total_jobs}</span>
          <span className="stats__tile-label">CV totali</span>
        </div>
        <div className="stats__tile">
          <span className="stats__tile-value">{stats.completed}</span>
          <span className="stats__tile-label">Completati</span>
        </div>
        <div className="stats__tile">
          <span className="stats__tile-value">{stats.needs_review + stats.failed}</span>
          <span className="stats__tile-label">Da rivedere / falliti</span>
        </div>
        <div className="stats__tile">
          <span className="stats__tile-value">{euro(stats.total_cost_eur)}</span>
          <span className="stats__tile-label">Spesa nel periodo</span>
        </div>
        <div className="stats__tile">
          <span className="stats__tile-value">{euro(stats.avg_cost_per_cv_eur)}</span>
          <span className="stats__tile-label">Costo medio per CV</span>
        </div>
      </div>

      <div className="stats__charts">
        <BarChart
          title="CV processati al giorno"
          points={stats.daily.map((d) => ({ date: d.date, value: d.jobs }))}
          format={(v) => `${v} CV`}
        />
        <BarChart
          title="Costo al giorno (EUR)"
          points={stats.daily.map((d) => ({ date: d.date, value: d.cost_eur }))}
          format={euro}
        />
      </div>
    </section>
  )
}
