import { useEffect, useState } from 'react'
import { BrowserRouter, Navigate, NavLink, useLocation } from 'react-router-dom'
import { CvUpload } from './components/CvUpload'
import { StatsDashboard } from './components/StatsDashboard'
import { ResultsList } from './components/ResultsList'
import { authEnabled, handleCallback, login, logout, userEmail } from './auth/auth'
import './App.css'

const PAGES = [
  { path: '/home', label: 'Carica CV' },
  { path: '/stats', label: 'Statistiche' },
  { path: '/results', label: 'Risultati' },
]

function AppShell() {
  //null = callback in corso; senza auth configurata si passa subito
  const [authed, setAuthed] = useState<boolean | null>(authEnabled ? null : true)
  const { pathname } = useLocation()

  useEffect(() => {
    if (authEnabled) {
      handleCallback().then(setAuthed)
    }
  }, [])

  if (authed === null) {
    return <main className="app"><p>Accesso in corso…</p></main>
  }

  if (!authed) {
    return (
      <main className="app">
        <h1>Skill Bridge</h1>
        <p className="app__subtitle">Accedi per caricare un CV.</p>
        <button onClick={() => void login()}>Accedi</button>
      </main>
    )
  }

  //percorsi sconosciuti (incluso "/", dove atterra il redirect di
  //Cognito) finiscono sulla home
  if (!PAGES.some((page) => page.path === pathname)) {
    return <Navigate to="/home" replace />
  }

  return (
    <main className="app">
      {authEnabled && (
        <div className="app__userbar">
          <span>{userEmail()}</span>
          <button className="app__logout" onClick={logout}>Esci</button>
        </div>
      )}
      <h1>Skill Bridge</h1>
      <nav className="app__tabs">
        {PAGES.map((page) => (
          <NavLink
            key={page.path}
            to={page.path}
            className={({ isActive }) => (isActive ? 'app__tab app__tab--active' : 'app__tab')}
          >
            {page.label}
          </NavLink>
        ))}
      </nav>
      {/* tutte le pagine restano montate (hidden, non unmount): il
          polling del job sopravvive alla navigazione e lo stato non
          si perde */}
      <div hidden={pathname !== '/home'} className="app__view">
        <p className="app__subtitle">
          Carica il tuo CV per iniziare l'analisi delle competenze.
        </p>
        <CvUpload />
      </div>
      <div hidden={pathname !== '/stats'} className="app__view">
        <StatsDashboard active={pathname === '/stats'} />
      </div>
      <div hidden={pathname !== '/results'} className="app__view">
        <ResultsList active={pathname === '/results'} />
      </div>
    </main>
  )
}

function App() {
  return (
    <BrowserRouter>
      <AppShell />
    </BrowserRouter>
  )
}

export default App
