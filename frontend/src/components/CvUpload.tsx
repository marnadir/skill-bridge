import { useCallback, useRef, useState } from 'react'
import type { ChangeEvent, DragEvent } from 'react'
import { uploadCv } from '../api/cv'
import './CvUpload.css'

//formati accettati per il CV e limite dimensione
const ACCEPTED_TYPES: Record<string, string> = {
  'application/pdf': 'PDF',
  'application/msword': 'DOC',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document':
    'DOCX',
}
const MAX_SIZE_MB = 5
const MAX_SIZE_BYTES = MAX_SIZE_MB * 1024 * 1024

type Status =
  | { kind: 'idle' }
  | { kind: 'selected'; file: File }
  | { kind: 'uploading'; file: File }
  | { kind: 'done'; fileName: string; simulated: boolean }
  | { kind: 'error'; message: string }

function validate(file: File): string | null {
  if (!(file.type in ACCEPTED_TYPES)) {
    return 'Formato non supportato: carica un file PDF, DOC o DOCX.'
  }
  if (file.size > MAX_SIZE_BYTES) {
    return `Il file supera il limite di ${MAX_SIZE_MB} MB.`
  }
  return null
}

function formatSize(bytes: number): string {
  return bytes < 1024 * 1024
    ? `${(bytes / 1024).toFixed(0)} KB`
    : `${(bytes / (1024 * 1024)).toFixed(1)} MB`
}

export function CvUpload() {
  const [status, setStatus] = useState<Status>({ kind: 'idle' })
  const [dragging, setDragging] = useState(false)
  const inputRef = useRef<HTMLInputElement>(null)

  const selectFile = useCallback((file: File) => {
    const error = validate(file)
    setStatus(error ? { kind: 'error', message: error } : { kind: 'selected', file })
  }, [])

  const onInputChange = (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0]
    if (file) selectFile(file)
    //reset per permettere di riselezionare lo stesso file
    event.target.value = ''
  }

  const onDrop = (event: DragEvent<HTMLDivElement>) => {
    event.preventDefault()
    setDragging(false)
    const file = event.dataTransfer.files?.[0]
    if (file) selectFile(file)
  }

  const onUpload = async () => {
    if (status.kind !== 'selected') return
    const { file } = status
    setStatus({ kind: 'uploading', file })
    try {
      const result = await uploadCv(file)
      setStatus({ kind: 'done', ...result })
    } catch (err) {
      setStatus({
        kind: 'error',
        message: err instanceof Error ? err.message : 'Errore imprevisto durante l’upload.',
      })
    }
  }

  const reset = () => setStatus({ kind: 'idle' })

  return (
    <section className="cv-upload">
      <div
        className={`cv-upload__dropzone${dragging ? ' cv-upload__dropzone--active' : ''}`}
        onDragOver={(e) => {
          e.preventDefault()
          setDragging(true)
        }}
        onDragLeave={() => setDragging(false)}
        onDrop={onDrop}
        onClick={() => inputRef.current?.click()}
        role="button"
        tabIndex={0}
        onKeyDown={(e) => {
          if (e.key === 'Enter' || e.key === ' ') inputRef.current?.click()
        }}
        aria-label="Carica il tuo CV"
      >
        <input
          ref={inputRef}
          type="file"
          accept=".pdf,.doc,.docx"
          onChange={onInputChange}
          hidden
        />
        <p className="cv-upload__title">Trascina qui il tuo CV</p>
        <p className="cv-upload__hint">
          oppure clicca per selezionarlo — PDF, DOC o DOCX, max {MAX_SIZE_MB} MB
        </p>
      </div>

      {status.kind === 'selected' && (
        <div className="cv-upload__panel">
          <p>
            <strong>{status.file.name}</strong>{' '}
            <span className="cv-upload__meta">
              ({ACCEPTED_TYPES[status.file.type]}, {formatSize(status.file.size)})
            </span>
          </p>
          <div className="cv-upload__actions">
            <button onClick={onUpload}>Carica CV</button>
            <button className="cv-upload__secondary" onClick={reset}>
              Annulla
            </button>
          </div>
        </div>
      )}

      {status.kind === 'uploading' && (
        <div className="cv-upload__panel">
          <p>Caricamento di <strong>{status.file.name}</strong> in corso…</p>
        </div>
      )}

      {status.kind === 'done' && (
        <div className="cv-upload__panel cv-upload__panel--success">
          <p>
            <strong>{status.fileName}</strong> caricato con successo
            {status.simulated && ' (simulato: backend non ancora configurato)'}.
          </p>
          <div className="cv-upload__actions">
            <button onClick={reset}>Carica un altro CV</button>
          </div>
        </div>
      )}

      {status.kind === 'error' && (
        <div className="cv-upload__panel cv-upload__panel--error">
          <p>{status.message}</p>
          <div className="cv-upload__actions">
            <button onClick={reset}>Riprova</button>
          </div>
        </div>
      )}
    </section>
  )
}
