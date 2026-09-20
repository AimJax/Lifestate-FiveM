import React from 'react'
import App from './App'

const path = '/npwd_lifestate_ojol'

const Icon = (props) =>
  React.createElement('svg', {
    ...props,
    viewBox: '0 0 24 24',
    fill: 'currentColor',
    xmlns: 'http://www.w3.org/2000/svg'
  },
    React.createElement('path', { d: 'M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.83 0-1.5.67-1.5 1.5S5.67 8 6.5 8h1.84L6 13l-2 1 1 1 2-1v1c0 .83.67 1.5 1.5 1.5h1c.83 0 1.5-.67 1.5-1.5v-1h4v1c0 .83.67 1.5 1.5 1.5h1c.83 0 1.5-.67 1.5-1.5v-1l1-1-1-1-2 1-1.16-3.99c.34-.29.56-.7.56-1.15 0-.83-.67-1.5-1.5-1.5zm-1.5 8.5h-1v-3h1v3zm-10-6h1.5v3h-1.5v-3zm11.5 6.5c-.55 0-1-.45-1-1s.45-1 1-1 1 .45 1 1-.45 1-1 1z' })
  )

const NotificationIcon = (props) =>
  React.createElement('svg', {
    ...props,
    viewBox: '0 0 24 24',
    fill: 'currentColor',
    xmlns: 'http://www.w3.org/2000/svg'
  },
    React.createElement('path', { d: 'M18.92 6.01C18.72 5.42 18.16 5 17.5 5h-11c-.83 0-1.5.67-1.5 1.5S5.67 8 6.5 8h1.84L6 13l-2 1 1 1 2-1v1c0 .83.67 1.5 1.5 1.5h1c.83 0 1.5-.67 1.5-1.5v-1h4v1c0 .83.67 1.5 1.5 1.5h1c.83 0 1.5-.67 1.5-1.5v-1l1-1-1-1-2 1-1.16-3.99c.34-.29.56-.7.56-1.15 0-.83-.67-1.5-1.5-1.5zm-1.5 8.5h-1v-3h1v3zm-10-6h1.5v3h-1.5v-3zm11.5 6.5c-.55 0-1-.45-1-1s.45-1 1-1 1 .45 1 1-.45 1-1 1z' })
  )

const config = () => ({
  id: 'npwd_lifestate_ojol',
  nameLocale: 'LAJU Mitra',
  color: '#ffffff',
  backgroundColor: '#333333',
  path,
  icon: Icon,
  app: App,
  notificationIcon: NotificationIcon
})

export default config
export { path }
