import { CvUpload } from './components/CvUpload'
import './App.css'

function App() {
  return (
    <main className="app">
      <h1>Skill Bridge</h1>
      <p className="app__subtitle">
        Carica il tuo CV per iniziare l’analisi delle competenze.
      </p>
      <CvUpload />
    </main>
  )
}

export default App
