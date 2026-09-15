import { useEffect, useState } from 'react'
import { CvUpload } from './components/CvUpload'
import { authEnabled, handleCallback, login, logout, userEmail } from './auth/auth'
import './App.css'

function App() {
  //null = callback in corso; senza auth configurata si passa subito
  const [authed, setAuthed] = useState<boolean | null>(authEnabled ? null : true)

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

  return (
    <main className="app">
      {authEnabled && (
        <div className="app__userbar">
          <span>{userEmail()}</span>
          <button className="app__logout" onClick={logout}>Esci</button>
        </div>
      )}
      <h1>Skill Bridge</h1>
      <p className="app__subtitle">
        Carica il tuo CV per iniziare l'analisi delle competenze.
      </p>
      <CvUpload />
    </main>
  )
}

export default App
