import React from 'react'

let cachedRide = null

const REASON_MESSAGES = {
  no_waypoint: 'Pasang waypoint di peta GTA untuk menentukan tujuan.',
  destination_not_on_road: 'Tujuan harus berada di jalan yang bisa dilalui.',
  unavailable: 'Aplikasi Ojol belum siap. Coba lagi sebentar.',
  already_active: 'Kamu masih punya order aktif.',
  invalid_destination: 'Tujuan tidak valid.',
  invalid_pickup: 'Lokasi jemput tidak valid.',
  invalid_payment: 'Metode pembayaran tidak valid.',
  too_close: 'Tujuan terlalu dekat. Minimal 150 meter.',
  too_far: 'Tujuan terlalu jauh.',
  insufficient_funds: 'SALDO TIDAK MENCUKUPI. Top up atau ganti metode pembayaran.',
  no_ride: 'Kamu tidak punya order aktif.',
  cannot_cancel_after_pickup: 'Perjalanan sudah berjalan.',
  too_fast: 'Terlalu cepat. Coba lagi sebentar.',
  callback_failed: 'Gagal menghubungi server Ojol.',
  not_ride_owner: 'Order ini bukan milikmu.',
  wrong_state: 'Aksi tidak tersedia sekarang.',
  payment_in_progress: 'Pembayaran sedang diproses.',
  already_rated: 'Kamu sudah memberi rating untuk perjalanan ini.',
  invalid_rating: 'Rating harus 1 sampai 5.',
  ride_not_found: 'Perjalanan tidak ditemukan.'
}

const STATUS_TEXT = {
  SEARCHING: 'MENCARI DRIVER...',
  ACCEPTED: 'Driver ditemukan',
  DRIVER_ENROUTE: 'Driver menuju lokasi jemput',
  DRIVER_ARRIVED: 'DRIVER SUDAH SAMPAI',
  PASSENGER_ONBOARD: 'PERJALANAN DIMULAI',
  ENROUTE_DESTINATION: 'PERJALANAN DIMULAI',
  COMPLETED: 'Perjalanan selesai',
  CANCELLED_CUSTOMER: 'Order dibatalkan',
  CANCELLED_DRIVER: 'Driver membatalkan order',
  FAILED: 'Order gagal'
}

const PAYMENT_LABELS = {
  cash: 'TUNAI',
  bank: 'TRANSFER'
}

const nui = (endpoint, body) =>
  fetch(`https://npwd_lifestate_ojol_customer/${endpoint}`, body
    ? {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body)
      }
    : undefined
  ).then((response) => response.json())

const formatDistance = (metres) => {
  if (metres === null || metres === undefined) return '--'
  if (metres < 1000) return `${Math.round(metres)} m`
  return `${(metres / 1000).toFixed(1)} km`
}

const formatRupiah = (amount) => `Rp${Number(amount || 0).toLocaleString('id-ID')}`

function App() {
  const [ride, setRide] = React.useState(cachedRide)
  const [preview, setPreview] = React.useState(null)
  const [payment, setPayment] = React.useState('cash')
  const [loading, setLoading] = React.useState(true)
  const [busy, setBusy] = React.useState(false)
  const [error, setError] = React.useState('')
  const [rating, setRating] = React.useState(0)
  const [ratedRideIds, setRatedRideIds] = React.useState([])

  // A ride disappears from the server as soon as it turns terminal, so a
  // completed ride must be remembered locally (per phone session) to keep the
  // rating screen visible until the customer rates it.
  const [finishedRide, setFinishedRide] = React.useState(null)

  const applyRide = (data) => {
    if (!data) {
      cachedRide = null
      setRide(null)
      return
    }

    cachedRide = data.terminal ? null : data
    setRide(cachedRide)

    if (data.terminal && data.status === 'COMPLETED') {
      setFinishedRide((previous) => {
        if (previous && previous.rideId === data.rideId) return previous
        return { ...data, rated: data.rated === true }
      })
    }
  }

  const loadRide = () =>
    nui('npwd:lifestate_ojol_customer:state')
      .then((response) => {
        if (response.status !== 'ok') return

        // Reopening the phone: if the live ride is gone but a completed,
        // unrated ride exists on the server, it arrives as a terminal payload.
        applyRide(response.data)
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))

  const loadPreview = () => {
    setBusy(true)
    setError('')

    return nui('npwd:lifestate_ojol_customer:preview')
      .then((response) => {
        if (response.status !== 'ok' || !response.data) {
          setError(REASON_MESSAGES.callback_failed)
          return
        }

        const data = response.data
        if (!data.success) {
          setPreview(null)
          setError(REASON_MESSAGES[data.reason] || 'Tidak bisa membaca tujuan.')
          return
        }

        setPreview(data)
        setError('')
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))
      .finally(() => setBusy(false))
  }

  React.useEffect(() => {
    let active = true

    Promise.all([loadRide()]).finally(() => {
      if (active) setLoading(false)
    })

    return () => {
      active = false
    }
  }, [])

  // Server-pushed ride changes (driver found, arrived, cancelled, completed).
  React.useEffect(() => {
    const onMessage = (event) => {
      const payload = event.data
      if (!payload || payload.app !== 'npwd_lifestate_ojol_customer') return
      if (payload.method !== 'rideState') return

      applyRide(payload.data)
    }

    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [])

  const requestRide = () => {
    setBusy(true)
    setError('')

    nui('npwd:lifestate_ojol_customer:request', { paymentMethod: payment })
      .then((response) => {
        if (response.status !== 'ok' || !response.data) {
          setError(REASON_MESSAGES.callback_failed)
          return
        }

        const data = response.data
        if (!data.success) {
          setError(REASON_MESSAGES[data.reason] || 'Gagal membuat order.')
          return
        }

        applyRide(data.data)
        setPreview(null)
        setError('')
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))
      .finally(() => setBusy(false))
  }

  const cancelRide = () => {
    setBusy(true)
    setError('')

    nui('npwd:lifestate_ojol_customer:cancel')
      .then((response) => {
        if (response.status !== 'ok') {
          setError(REASON_MESSAGES[(response.data && response.data.reason) || 'unknown'] || 'Gagal membatalkan order.')
          return
        }

        applyRide(null)
        setPreview(null)
        setError('')
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))
      .finally(() => setBusy(false))
  }

  const switchPayment = (method) => {
    setBusy(true)
    setError('')

    nui('npwd:lifestate_ojol_customer:changePayment', { method })
      .then((response) => {
        if (response.status !== 'ok' || !response.data || !response.data.success) {
          const reason = response.data && response.data.reason
          setError(REASON_MESSAGES[reason] || 'Gagal mengganti pembayaran.')
          return
        }

        if (response.data.data) applyRide(response.data.data)
        setError('')
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))
      .finally(() => setBusy(false))
  }

  const submitRating = () => {
    if (!finishedRide || rating < 1) return

    setBusy(true)
    setError('')

    nui('npwd:lifestate_ojol_customer:rate', { rideId: finishedRide.rideId, rating })
      .then((response) => {
        if (response.status !== 'ok' || !response.data || !response.data.success) {
          const reason = response.data && response.data.reason
          setError(REASON_MESSAGES[reason] || 'Gagal mengirim rating.')
          return
        }

        setFinishedRide((previous) => ({ ...previous, rated: true }))
        setRatedRideIds((ids) => [...ids, finishedRide.rideId])
        setError('')
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))
      .finally(() => setBusy(false))
  }

  const balanceFor = (method) => {
    if (!preview || !preview.balances) return 0
    return preview.balances[method] || 0
  }

  const canAfford = preview ? balanceFor(payment) >= preview.fare : false

  // Screen selection -----------------------------------------------------------
  let screen

  if (finishedRide) {
    screen = (
      <>
        <div style={styles.statusHeader}>Perjalanan selesai</div>

        {finishedRide.driver ? (
          <div style={styles.driverCard}>
            {finishedRide.driver.profilePhoto ? (
              <img src={finishedRide.driver.profilePhoto} alt="Driver" style={styles.driverPhoto} />
            ) : (
              <div style={styles.driverPhotoPlaceholder}>OJOL</div>
            )}
            <div style={styles.driverName}>{finishedRide.driver.name}</div>
          </div>
        ) : null}

        {finishedRide.rated || ratedRideIds.includes(finishedRide.rideId) ? (
          <div style={styles.completedNote}>Terima kasih! Rating kamu sudah terkirim.</div>
        ) : (
          <>
            <div style={styles.hint}>BAGAIMANA PERJALANAN ANDA?</div>
            <div style={styles.starsRow}>
              {[1, 2, 3, 4, 5].map((value) => (
                <button
                  key={value}
                  style={{ ...styles.star, ...(value <= rating ? styles.starActive : {}) }}
                  disabled={busy}
                  onClick={() => setRating(value)}
                >
                  ★
                </button>
              ))}
            </div>

            <button
              style={{ ...styles.button, ...styles.primaryButton }}
              disabled={busy || rating < 1}
              onClick={submitRating}
            >
              KIRIM RATING
            </button>
          </>
        )}

        <button
          style={{ ...styles.button, ...styles.secondaryButton }}
          disabled={busy}
          onClick={() => {
            setFinishedRide(null)
            setRating(0)
          }}
        >
          SELESAI
        </button>
      </>
    )
  } else if (ride) {
    screen = (
      <>
        <div style={styles.statusHeader}>{STATUS_TEXT[ride.status] || ride.status}</div>

        {ride.driver ? (
          <div style={styles.driverCard}>
            {ride.driver.profilePhoto ? (
              <img src={ride.driver.profilePhoto} alt="Driver" style={styles.driverPhoto} />
            ) : (
              <div style={styles.driverPhotoPlaceholder}>OJOL</div>
            )}
            <div style={styles.driverName}>{ride.driver.name}</div>
            <div style={styles.driverMeta}>
              {ride.driver.rank ? `${ride.driver.rank} - ` : ''}
              {ride.driver.rating ? `Rating ${Number(ride.driver.rating).toFixed(1)}` : 'Driver baru'}
            </div>
          </div>
        ) : null}

        {ride.paymentFailed ? (
          <div style={styles.paymentFailed}>
            SALDO TIDAK MENCUKUPI
            <div style={styles.hint}>Top up saldo kamu atau ganti metode pembayaran.</div>

            <div style={styles.paymentRow}>
              {['cash', 'bank'].map((method) => (
                <button
                  key={method}
                  style={{
                    ...styles.paymentOption,
                    ...(ride.paymentMethod === method ? styles.paymentOptionActive : {})
                  }}
                  disabled={busy || ride.paymentMethod === method}
                  onClick={() => switchPayment(method)}
                >
                  <div style={styles.paymentLabel}>{PAYMENT_LABELS[method]} (Ganti Pembayaran)</div>
                </button>
              ))}
            </div>
          </div>
        ) : null}

        <div style={styles.card}>
          <div style={styles.line}>
            <span style={styles.label}>Lokasi jemput</span>
            <span style={styles.value}>{`${ride.pickup.x.toFixed(0)}, ${ride.pickup.y.toFixed(0)}`}</span>
          </div>
          <div style={styles.line}>
            <span style={styles.label}>Tujuan</span>
            <span style={styles.value}>{`${ride.destination.x.toFixed(0)}, ${ride.destination.y.toFixed(0)}`}</span>
          </div>
          <div style={styles.line}>
            <span style={styles.label}>Jarak</span>
            <span style={styles.value}>{formatDistance(ride.distanceMeters)}</span>
          </div>
          <div style={styles.line}>
            <span style={styles.label}>Tarif</span>
            <span style={{ ...styles.value, ...styles.fare }}>{ride.fareText || formatRupiah(ride.fare)}</span>
          </div>
          <div style={styles.line}>
            <span style={styles.label}>Pembayaran</span>
            <span style={styles.value}>{PAYMENT_LABELS[ride.paymentMethod] || ride.paymentMethod}</span>
          </div>
        </div>

        {ride.driver && (ride.status === 'DRIVER_ARRIVED') ? (
          <div style={styles.completedNote}>Silakan menuju driver Anda.</div>
        ) : null}

        <button
          style={{ ...styles.button, ...styles.dangerButton }}
          disabled={busy}
          onClick={cancelRide}
        >
          BATALKAN
        </button>
      </>
    )
  } else {
    screen = (
      <>
        <div style={styles.hint}>
          Buka peta GTA, pasang waypoint di tujuan, lalu kembali ke aplikasi ini.
        </div>

        <button style={{ ...styles.button, ...styles.secondaryButton }} disabled={busy} onClick={loadPreview}>
          GUNAKAN WAYPOINT
        </button>

        {preview ? (
          <>
            <div style={styles.card}>
              <div style={styles.line}>
                <span style={styles.label}>Jarak perjalanan</span>
                <span style={styles.value}>{formatDistance(preview.distanceMeters)}</span>
              </div>
              <div style={styles.line}>
                <span style={styles.label}>Tarif</span>
                <span style={{ ...styles.value, ...styles.fare }}>
                  {preview.fareText || formatRupiah(preview.fare)}
                </span>
              </div>
              <div style={styles.line}>
                <span style={styles.label}>Pendapatan driver</span>
                <span style={styles.value}>
                  {preview.driverPayoutText || formatRupiah(preview.driverPayout)}
                </span>
              </div>
            </div>

            <div style={styles.paymentRow}>
              {['cash', 'bank'].map((method) => (
                <button
                  key={method}
                  style={{
                    ...styles.paymentOption,
                    ...(payment === method ? styles.paymentOptionActive : {})
                  }}
                  disabled={busy}
                  onClick={() => setPayment(method)}
                >
                  <div style={styles.paymentLabel}>{PAYMENT_LABELS[method]}</div>
                  <div style={styles.paymentBalance}>{formatRupiah(balanceFor(method))}</div>
                </button>
              ))}
            </div>

            {!canAfford ? (
              <div style={styles.warning}>Saldo {PAYMENT_LABELS[payment]} tidak cukup untuk tarif ini.</div>
            ) : null}

            <button
              style={{ ...styles.button, ...styles.primaryButton }}
              disabled={busy || !canAfford}
              onClick={requestRide}
            >
              PESAN OJOL
            </button>
          </>
        ) : null}
      </>
    )
  }

  return (
    <div style={styles.container}>
      <div style={styles.app}>
        <div style={styles.title}>OJOL</div>
        <div style={styles.subtitle}>Pesan Ojek Online</div>

        {screen}

        {loading ? <div style={styles.hint}>Memuat...</div> : null}
        <div style={styles.error}>{error}</div>
      </div>
    </div>
  )
}

const styles = {
  container: {
    background: '#0f1512',
    color: '#ffffff',
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif',
    width: '100%',
    flex: 1,
    maxHeight: '100%',
    overflow: 'auto',
    boxSizing: 'border-box',
    display: 'flex',
    alignItems: 'flex-start',
    justifyContent: 'center',
    padding: '16px'
  },
  app: {
    width: '100%',
    maxWidth: '380px',
    background: '#16201b',
    borderRadius: '16px',
    padding: '24px',
    textAlign: 'center',
    boxSizing: 'border-box',
    boxShadow: '0 8px 32px rgba(0,0,0,0.4)'
  },
  title: {
    fontSize: '22px',
    fontWeight: '700',
    letterSpacing: '1px',
    marginBottom: '4px'
  },
  subtitle: {
    color: '#7f8c85',
    fontSize: '12px',
    textTransform: 'uppercase',
    letterSpacing: '2px',
    marginBottom: '20px'
  },
  statusHeader: {
    color: '#22c55e',
    fontSize: '15px',
    fontWeight: '700',
    letterSpacing: '1px',
    marginBottom: '16px'
  },
  hint: {
    color: '#8b978f',
    fontSize: '12px',
    lineHeight: '1.5',
    marginBottom: '16px'
  },
  driverCard: {
    background: '#111815',
    border: '1px solid #24312a',
    borderRadius: '12px',
    padding: '16px',
    marginBottom: '14px'
  },
  driverPhoto: {
    width: '64px',
    height: '64px',
    borderRadius: '50%',
    objectFit: 'cover',
    display: 'block',
    margin: '0 auto 10px',
    border: '2px solid #24312a'
  },
  driverPhotoPlaceholder: {
    width: '64px',
    height: '64px',
    borderRadius: '50%',
    background: '#24312a',
    color: '#7f8c85',
    fontSize: '11px',
    fontWeight: '700',
    lineHeight: '64px',
    margin: '0 auto 10px'
  },
  driverName: {
    fontSize: '15px',
    fontWeight: '600'
  },
  driverMeta: {
    color: '#8b978f',
    fontSize: '12px',
    marginTop: '4px'
  },
  card: {
    background: '#111815',
    border: '1px solid #24312a',
    borderRadius: '12px',
    padding: '16px',
    marginBottom: '14px',
    textAlign: 'left'
  },
  line: {
    display: 'flex',
    justifyContent: 'space-between',
    gap: '12px',
    marginBottom: '6px'
  },
  label: {
    color: '#8b978f',
    fontSize: '12px'
  },
  value: {
    color: '#ffffff',
    fontSize: '13px',
    fontWeight: '600',
    textAlign: 'right'
  },
  fare: {
    color: '#22c55e'
  },
  starsRow: {
    display: 'flex',
    justifyContent: 'center',
    gap: '8px',
    marginBottom: '16px'
  },
  star: {
    background: 'none',
    border: 'none',
    color: '#3a463f',
    fontSize: '34px',
    lineHeight: '1',
    cursor: 'pointer',
    padding: '0'
  },
  starActive: {
    color: '#f59e0b'
  },
  completedNote: {
    background: '#16241c',
    border: '1px solid #24312a',
    borderRadius: '10px',
    color: '#22c55e',
    fontSize: '13px',
    fontWeight: '600',
    padding: '12px',
    marginBottom: '14px'
  },
  paymentFailed: {
    background: '#2a1414',
    border: '1px solid #ef4444',
    borderRadius: '10px',
    color: '#ef4444',
    fontSize: '13px',
    fontWeight: '600',
    padding: '12px',
    marginBottom: '14px'
  },
  paymentRow: {
    display: 'flex',
    gap: '10px',
    marginTop: '10px'
  },
  paymentOption: {
    flex: 1,
    background: '#111815',
    borderWidth: '1px',
    borderStyle: 'solid',
    borderColor: '#24312a',
    borderRadius: '10px',
    padding: '12px',
    color: '#ffffff',
    cursor: 'pointer'
  },
  paymentOptionActive: {
    borderColor: '#22c55e',
    background: '#16241c'
  },
  paymentLabel: {
    fontSize: '12px',
    fontWeight: '700',
    letterSpacing: '1px'
  },
  paymentBalance: {
    color: '#8b978f',
    fontSize: '11px',
    marginTop: '4px'
  },
  warning: {
    color: '#f59e0b',
    fontSize: '12px',
    marginBottom: '12px'
  },
  button: {
    width: '100%',
    padding: '14px',
    border: 'none',
    borderRadius: '10px',
    fontSize: '15px',
    fontWeight: '700',
    letterSpacing: '0.5px',
    cursor: 'pointer',
    marginBottom: '10px'
  },
  primaryButton: {
    background: '#22c55e',
    color: '#000000'
  },
  secondaryButton: {
    background: '#24312a',
    color: '#ffffff'
  },
  dangerButton: {
    background: '#ef4444',
    color: '#ffffff'
  },
  error: {
    color: '#ef4444',
    fontSize: '13px',
    marginTop: '12px'
  }
}

export default App
