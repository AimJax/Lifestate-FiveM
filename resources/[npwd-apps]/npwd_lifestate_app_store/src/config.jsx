import React from 'react'
import App from './App'

const path = '/npwd_lifestate_app_store'

const Icon = (props) =>
  React.createElement('svg', {
    ...props,
    viewBox: '0 0 24 24',
    fill: 'currentColor',
    xmlns: 'http://www.w3.org/2000/svg'
  },
    React.createElement('path', {
      d: 'M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z'
    })
  )

const NotificationIcon = (props) =>
  React.createElement('svg', {
    ...props,
    viewBox: '0 0 24 24',
    fill: 'currentColor',
    xmlns: 'http://www.w3.org/2000/svg'
  },
    React.createElement('path', {
      d: 'M5 20h14v-2H5v2zM19 9h-4V3H9v6H5l7 7 7-7z'
    })
  )

// NPWD calls this function on the default export, so ./config MUST be callable.
const config = () => ({
  id: 'npwd_lifestate_app_store',
  nameLocale: 'Lifestate App Store',
  color: '#ffffff',
  backgroundColor: '#1b2440',
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
})

export default config
export { path }
