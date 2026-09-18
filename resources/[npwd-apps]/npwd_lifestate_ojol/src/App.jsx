import React from 'react'

let cachedDriverState = null
let cachedRideState = null

const REASON_MESSAGES = {
  not_registered: 'ANDA BELUM TERDAFTAR SEBAGAI DRIVER OJOL',
  not_eligible: 'Order ini tidak tersedia untukmu.',
  order_already_taken: 'Order sudah diambil driver lain.',
  ride_not_found: 'Order tidak ditemukan.',
  no_offer: 'Order ini sudah tidak ditawarkan lagi.',
  no_ride: 'Kamu sedang tidak punya order aktif.',
  invalid_ride: 'Order tidak valid.',
  busy: 'Kamu sedang menerima order.',
  busy_active_ride: 'Selesaikan atau batalkan order aktif terlebih dahulu.',
  too_fast: 'Terlalu cepat. Coba lagi sebentar.',
  invalid_state: 'Gagal mengubah status Ojol.',
  callback_failed: 'Gagal mengambil status Ojol.',
  not_ride_owner: 'Order ini bukan milikmu.',
  wrong_state: 'Aksi tidak tersedia untuk status order ini.',
  too_far_from_pickup: 'Kamu terlalu jauh dari titik jemput.',
  too_far_from_destination: 'Kamu terlalu jauh dari tujuan.',
  customer_not_on_bike: 'Penumpang belum naik motor.',
  customer_not_near: 'Penumpang tidak berada di dekatmu.',
  customer_offline: 'Penumpang tidak terhubung.',
  offline: 'Kamu sedang tidak online.',
  payment_in_progress: 'Pembayaran sedang diproses.',
  already_paid_or_processing: 'Order ini sudah dibayar.',
  insufficient_funds: 'PEMBAYARAN GAGAL - saldo pelanggan tidak mencukupi.',
  payout_failed: 'Pembayaran gagal. Coba lagi.',
  company_failed: 'Pembayaran gagal (kesalahan perusahaan).',
  customer_wallet_failed: 'Pembayaran gagal (dompet pelanggan).'
}

const RANK_LABELS = {
  driver: 'Driver',
  senior_driver: 'Senior Driver',
  supervisor: 'Supervisor',
  ceo: 'CEO'
}

const ORDER_STATUS_TEXT = {
  SEARCHING: 'Mencari order...',
  ACCEPTED: 'Order diterima',
  DRIVER_ENROUTE: 'Menuju titik jemput',
  DRIVER_ARRIVED: 'Tiba di titik jemput',
  PASSENGER_ONBOARD: 'Penumpang di atas motor',
  ENROUTE_DESTINATION: 'Menuju tujuan',
  COMPLETED: 'Order selesai',
  CANCELLED_CUSTOMER: 'Dibatalkan penumpang',
  CANCELLED_DRIVER: 'Order dibatalkan',
  FAILED: 'Order gagal'
}

const nui = (endpoint, body) =>
  fetch(`https://npwd_lifestate_ojol/${endpoint}`, body
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

function App() {
  const [driverState, setDriverState] = React.useState(cachedDriverState)
  const [rideState, setRideState] = React.useState(cachedRideState)
  const [loading, setLoading] = React.useState(cachedDriverState === null)
  const [submitting, setSubmitting] = React.useState(false)
  const [acting, setActing] = React.useState(null)
  const [error, setError] = React.useState('')

  const applyDriverState = (data) => {
    cachedDriverState = data
    setDriverState(data)
  }

  const applyRideState = (data) => {
    cachedRideState = data
    setRideState(data)
  }

  const refreshDriverState = () =>
    nui('npwd:lifestate_ojol:getDriverState')
      .then((response) => {
        if (response.status !== 'ok' || !response.data) {
          setError(REASON_MESSAGES.callback_failed)
          return
        }
        applyDriverState(response.data)
        setError('')
      })
      .catch(() => setError(REASON_MESSAGES.callback_failed))

  const refreshRideState = () =>
    nui('npwd:lifestate_ojol:getDriverRideState')
      .then((response) => {
        if (response.status !== 'ok' || !response.data) return
        applyRideState(response.data)
      })
      .catch(() => {})

  React.useEffect(() => {
    let active = true

    Promise.all([refreshDriverState(), refreshRideState()]).finally(() => {
      if (active) setLoading(false)
    })

    return () => {
      active = false
    }
  }, [])

  // Server-pushed ride state (offer received, ride accepted, order finished).
  React.useEffect(() => {
    const onMessage = (event) => {
      const payload = event.data
      if (!payload || payload.app !== 'npwd_lifestate_ojol') return

      if (payload.method === 'rideState' && payload.data) {
        applyRideState(payload.data)
      } else if (payload.method === 'driverState' && payload.data) {
        applyDriverState(payload.data)
      }
    }

    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [])

  const changeDuty = (desiredState) => {
    setSubmitting(true)
    setError('')

    nui('npwd:lifestate_ojol:setDriverDuty', { desiredState })
      .then((response) => {
        if (response.status !== 'ok' || !response.data || !response.data.success) {
          const reason = response.data && response.data.reason
          setError(REASON_MESSAGES[reason] || REASON_MESSAGES.invalid_state)
          return
        }

        applyDriverState(response.data)
        setError('')
        refreshRideState()
      })
      .catch(() => setError(REASON_MESSAGES.invalid_state))
      .finally(() => setSubmitting(false))
  }

  const answerOffer = (rideId, action) => {
    setActing(rideId)
    setError('')

    nui(`npwd:lifestate_ojol:${action}`, { rideId })
      .then((response) => {
        if (response.status !== 'ok' || !response.data || !response.data.success) {
          const reason = response.data && response.data.reason
          setError(REASON_MESSAGES[reason] || 'Gagal memproses order.')
          refreshRideState()
          return
        }

        if (response.data.data) applyRideState(response.data.data)
        setError('')
        refreshDriverState()
      })
      .catch(() => setError('Gagal memproses order.'))
      .finally(() => setActing(null))
  }

  const cancelOrder = () => {
    setActing('cancel')
    setError('')

    nui('npwd:lifestate_ojol:cancelDriverRide')
      .then((response) => {
        if (response.status !== 'ok' || !response.data || !response.data.success) {
          const reason = response.data && response.data.reason
          setError(REASON_MESSAGES[reason] || 'Gagal membatalkan order.')
          return
        }

        if (response.data.data) applyRideState(response.data.data)
        setError('')
        refreshDriverState()
      })
      .catch(() => setError('Gagal membatalkan order.'))
      .finally(() => setActing(null))
  }

  // Phase 3C in-trip actions. Each returns the fresh driver view on success.
  const tripAction = (action, rideId) => {
    setActing(action)
    setError('')

    nui(`npwd:lifestate_ojol:${action}`, { rideId })
      .then((response) => {
        if (response.status !== 'ok' || !response.data || !response.data.success) {
          const reason = response.data && response.data.reason
          setError(REASON_MESSAGES[reason] || 'Gagal memproses order.')
          refreshRideState()
          return
        }

        if (response.data.data) applyRideState(response.data.data)
        setError('')
        refreshDriverState()
      })
      .catch(() => setError('Gagal memproses order.'))
      .finally(() => setActing(null))
  }

  const registered = driverState?.registered
  const online = driverState?.online
  const busy = driverState?.busy
  const rank = driverState?.rank
  const offers = rideState?.offers || []
  const activeRide = rideState?.active

  return (
    <div style={styles.container}>
      <div style={styles.app}>
        <div style={styles.title}>OJOL</div>
        <div style={styles.subtitle}>Lifestate Ojol Driver</div>

        {registered ? (
          <>
            <div style={styles.statusRow}>
              <span style={{ ...styles.dot, ...(busy ? styles.busyDot : online ? styles.onlineDot : {}) }} />
              <span style={styles.statusText}>
                {loading && !driverState ? '--' : busy ? 'BUSY' : online ? 'ONLINE' : 'OFFLINE'}
              </span>
            </div>

            <div style={styles.metaRow}>
              <div style={styles.metaItem}>
                <span style={styles.metaLabel}>Rank</span>
                <span style={styles.metaValue}>{rank ? RANK_LABELS[rank] || rank : '--'}</span>
              </div>
              <div style={styles.metaItem}>
                <span style={styles.metaLabel}>Rating</span>
                <span style={styles.metaValue}>
                  {driverState?.rating ? Number(driverState.rating).toFixed(1) : 'Baru'}
                </span>
              </div>
            </div>

            {driverState?.profilePhoto ? (
              <img src={driverState.profilePhoto} alt="Foto profil" style={styles.profilePhoto} />
            ) : null}

            {activeRide ? (
              <div style={styles.orderCard}>
                <div style={styles.orderHeader}>ORDER AKTIF</div>
                <div style={styles.orderStatus}>
                  {ORDER_STATUS_TEXT[activeRide.status] || activeRide.status}
                </div>

                <div style={styles.orderLine}>
                  <span style={styles.orderLabel}>Penumpang</span>
                  <span style={styles.orderValue}>{activeRide.customerName}</span>
                </div>
                <div style={styles.orderLine}>
                  <span style={styles.orderLabel}>Jarak perjalanan</span>
                  <span style={styles.orderValue}>{formatDistance(activeRide.distanceMeters)}</span>
                </div>
                <div style={styles.orderLine}>
                  <span style={styles.orderLabel}>Tarif pelanggan</span>
                  <span style={styles.orderValue}>{activeRide.fareText}</span>
                </div>
                <div style={styles.orderLine}>
                  <span style={styles.orderLabel}>Pendapatan kamu</span>
                  <span style={{ ...styles.orderValue, ...styles.payout }}>{activeRide.driverPayoutText}</span>
                </div>

                {activeRide.status === 'DRIVER_ENROUTE' ? (
                  <button
                    style={{ ...styles.button, ...styles.acceptButton, marginTop: '14px' }}
                    disabled={acting !== null}
                    onClick={() => tripAction('driverArrived', activeRide.rideId)}
                  >
                    SAYA SUDAH SAMPAI
                  </button>
                ) : null}

                {activeRide.status === 'DRIVER_ARRIVED' ? (
                  <button
                    style={{ ...styles.button, ...styles.acceptButton, marginTop: '14px' }}
                    disabled={acting !== null}
                    onClick={() => tripAction('passengerBoarded', activeRide.rideId)}
                  >
                    PENUMPANG SUDAH NAIK
                  </button>
                ) : null}

                {activeRide.status === 'ENROUTE_DESTINATION' ? (
                  <button
                    style={{ ...styles.button, ...styles.acceptButton, marginTop: '14px' }}
                    disabled={acting !== null}
                    onClick={() => tripAction('completeRide', activeRide.rideId)}
                  >
                    SELESAIKAN PERJALANAN
                  </button>
                ) : null}

                {activeRide.paymentFailed ? (
                  <div style={styles.paymentFailed}>
                    PEMBAYARAN GAGAL - saldo pelanggan tidak mencukupi.
                    <div style={styles.hint}>Tunggu pelanggan top up atau ganti metode pembayaran.</div>
                  </div>
                ) : null}

                <button
                  style={{ ...styles.button, ...styles.dangerButton, marginTop: '14px' }}
                  disabled={acting !== null}
                  onClick={cancelOrder}
                >
                  BATALKAN ORDER
                </button>

                <div style={styles.hint}>Selesaikan atau batalkan order aktif terlebih dahulu.</div>
              </div>
            ) : null}

            {!activeRide && offers.length > 0 ? (
              <div style={styles.orderCard}>
                <div style={styles.orderHeader}>ORDER BARU</div>

                {offers.map((offer) => (
                  <div key={offer.rideId} style={styles.offerBlock}>
                    <div style={styles.orderLine}>
                      <span style={styles.orderLabel}>Customer</span>
                      <span style={styles.orderValue}>{offer.customerName}</span>
                    </div>
                    <div style={styles.orderLine}>
                      <span style={styles.orderLabel}>Jarak ke penumpang</span>
                      <span style={styles.orderValue}>{formatDistance(offer.distanceToPickupMeters)}</span>
                    </div>
                    <div style={styles.orderLine}>
                      <span style={styles.orderLabel}>Jarak perjalanan</span>
                      <span style={styles.orderValue}>{formatDistance(offer.rideDistanceMeters)}</span>
                    </div>
                    <div style={styles.orderLine}>
                      <span style={styles.orderLabel}>Tarif pelanggan</span>
                      <span style={styles.orderValue}>{offer.fareText}</span>
                    </div>
                    <div style={styles.orderLine}>
                      <span style={styles.orderLabel}>Pendapatan driver</span>
                      <span style={{ ...styles.orderValue, ...styles.payout }}>{offer.driverPayoutText}</span>
                    </div>

                    <div style={styles.offerButtons}>
                      <button
                        style={{ ...styles.button, ...styles.acceptButton }}
                        disabled={acting !== null}
                        onClick={() => answerOffer(offer.rideId, 'acceptRideOffer')}
                      >
                        TERIMA
                      </button>
                      <button
                        style={{ ...styles.button, ...styles.declineButton }}
                        disabled={acting !== null}
                        onClick={() => answerOffer(offer.rideId, 'rejectRideOffer')}
                      >
                        TOLAK
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            ) : null}

            {!busy && (
              <button
                style={{ ...styles.button, ...(online ? styles.offlineButton : styles.onlineButton) }}
                disabled={submitting}
                onClick={() => changeDuty(!online)}
              >
                {online ? 'SELESAI NGE-OJOL' : 'MULAI NGE-OJOL'}
              </button>
            )}
          </>
        ) : (
          <>
            <div style={styles.desc}>{REASON_MESSAGES.not_registered}</div>
            <div style={styles.hint}>Hubungi CEO Ojol untuk mendaftar sebagai driver.</div>
          </>
        )}

        <div style={styles.error}>{error}</div>
      </div>
    </div>
  )
}

const styles = {
  container: {
    background: '#111111',
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
    background: '#1a1a1a',
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
    color: '#888888',
    fontSize: '12px',
    textTransform: 'uppercase',
    letterSpacing: '2px',
    marginBottom: '20px'
  },
  statusRow: {
    display: 'flex',
    alignItems: 'center',
    justifyContent: 'center',
    gap: '8px',
    marginBottom: '12px'
  },
  dot: {
    width: '12px',
    height: '12px',
    borderRadius: '50%',
    background: '#ef4444',
    boxShadow: '0 0 8px #ef4444'
  },
  onlineDot: {
    background: '#22c55e',
    boxShadow: '0 0 8px #22c55e'
  },
  busyDot: {
    background: '#f59e0b',
    boxShadow: '0 0 8px #f59e0b'
  },
  statusText: {
    fontSize: '16px',
    fontWeight: '600'
  },
  desc: {
    color: '#888888',
    fontSize: '13px',
    marginBottom: '24px',
    lineHeight: '1.4'
  },
  hint: {
    color: '#666666',
    fontSize: '12px',
    marginTop: '10px',
    lineHeight: '1.4'
  },
  metaRow: {
    display: 'flex',
    justifyContent: 'center',
    gap: '24px',
    marginBottom: '20px'
  },
  metaItem: {
    display: 'flex',
    flexDirection: 'column',
    gap: '2px'
  },
  metaLabel: {
    color: '#888888',
    fontSize: '11px',
    textTransform: 'uppercase',
    letterSpacing: '1px'
  },
  metaValue: {
    color: '#ffffff',
    fontSize: '14px',
    fontWeight: '600'
  },
  profilePhoto: {
    width: '72px',
    height: '72px',
    borderRadius: '50%',
    objectFit: 'cover',
    margin: '0 auto 20px',
    display: 'block',
    border: '2px solid #2f2f2f'
  },
  orderCard: {
    background: '#141414',
    border: '1px solid #2f2f2f',
    borderRadius: '12px',
    padding: '16px',
    marginBottom: '18px',
    textAlign: 'left'
  },
  orderHeader: {
    color: '#f59e0b',
    fontSize: '12px',
    fontWeight: '700',
    letterSpacing: '2px',
    marginBottom: '10px',
    textAlign: 'center'
  },
  orderStatus: {
    color: '#ffffff',
    fontSize: '14px',
    fontWeight: '600',
    textAlign: 'center',
    marginBottom: '12px'
  },
  offerBlock: {
    borderTop: '1px solid #2f2f2f',
    paddingTop: '10px',
    marginTop: '10px'
  },
  orderLine: {
    display: 'flex',
    justifyContent: 'space-between',
    gap: '12px',
    marginBottom: '6px'
  },
  orderLabel: {
    color: '#888888',
    fontSize: '12px'
  },
  orderValue: {
    color: '#ffffff',
    fontSize: '13px',
    fontWeight: '600',
    textAlign: 'right'
  },
  payout: {
    color: '#22c55e'
  },
  paymentFailed: {
    background: '#2a1414',
    border: '1px solid #ef4444',
    borderRadius: '10px',
    color: '#ef4444',
    fontSize: '13px',
    fontWeight: '600',
    marginTop: '14px',
    padding: '12px'
  },
  offerButtons: {
    display: 'flex',
    gap: '10px',
    marginTop: '14px'
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
    transition: 'opacity 0.2s'
  },
  acceptButton: {
    background: '#22c55e',
    color: '#000000'
  },
  declineButton: {
    background: '#2f2f2f',
    color: '#ffffff'
  },
  dangerButton: {
    background: '#ef4444',
    color: '#ffffff'
  },
  onlineButton: {
    background: '#22c55e',
    color: '#000000'
  },
  offlineButton: {
    background: '#ef4444',
    color: '#ffffff'
  },
  error: {
    color: '#ef4444',
    fontSize: '13px',
    marginTop: '16px'
  }
}

export default App
