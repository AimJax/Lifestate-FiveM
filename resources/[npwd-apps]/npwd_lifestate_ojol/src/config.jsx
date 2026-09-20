import React from 'react'
import App from './App'

const path = '/npwd_lifestate_ojol'

// Same LAJU mark as the customer app (one brand, two roles). The Mitra
// distinction is a single small diamond badge - no second logo, no words.
// Monochrome: rendered in `currentColor` so NPWD/store tiles decide the ink.
const LAJU_STEM = '3,3 8,3 8,15 3,15'
const LAJU_FOOT = '3,15 13,15 18.5,17.5 13,20 3,20'
const MITRA_BADGE = '17.5,3.5 20,6 17.5,8.5 15,6'

// Expanded home-screen viewBox (internal padding) so the mark occupies the
// same fraction of the NPWD home tile as it does of the App Store tile.
// Geometry untouched - verified side-by-side against the store version.
const HOME_VIEWBOX = '-3 -3 30 30'

const Icon = (props) => (
  <svg
    {...props}
    viewBox={HOME_VIEWBOX}
    fill="currentColor"
    xmlns="http://www.w3.org/2000/svg"
  >
    <polygon points={LAJU_STEM} />
    <polygon points={LAJU_FOOT} />
    <polygon points={MITRA_BADGE} />
  </svg>
)

// Notifications keep the full-bleed geometry: they render much smaller and
// must stay maximally legible rather than match tile padding.
const NotificationIcon = (props) => (
  <svg
    {...props}
    viewBox="0 0 24 24"
    fill="currentColor"
    xmlns="http://www.w3.org/2000/svg"
  >
    <polygon points={LAJU_STEM} />
    <polygon points={LAJU_FOOT} />
    <polygon points={MITRA_BADGE} />
  </svg>
)

const config = () => ({
  id: 'npwd_lifestate_ojol',
  nameLocale: 'LAJU Mitra',
  color: '#D71920',
  backgroundColor: '#FFFFFF',
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
})

export default config
export { path }
