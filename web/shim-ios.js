// iOS bridge shim. WKWebView only offers async message passing, so every call is a
// request id plus a promise, resolved by the Swift side.
(function () {
  if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.sonekk) return
  if (window.sonekk) return

  var sequence = 0
  var pending = {}
  var listeners = []

  function send(method, args) {
    window.webkit.messageHandlers.sonekk.postMessage({ id: ++sequence, method: method, args: args || [] })
    var id = sequence
    return new Promise(function (resolve) {
      pending[id] = resolve
    })
  }

  function fire(method, args) {
    send(method, args)
  }

  window.__sonekkReply = function (id, json) {
    var resolve = pending[id]
    if (!resolve) return
    delete pending[id]
    var value = null
    try { value = JSON.parse(json) } catch (e) { value = null }
    resolve(value)
  }

  window.__sonekkEvent = function (json) {
    var event = JSON.parse(json)
    for (var i = 0; i < listeners.length; i += 1) listeners[i](event)
  }

  window.sonekk = {
    settings: {
      get: function () { return send('settings') },
      save: function (patch) { return send('saveSettings', [patch]) },
      setKey: function (provider, key) { return send('setKey', [provider, key]) },
      test: function (provider) { return send('testProvider', [provider]) },
      models: function (provider) { return send('models', [provider]) },
      pickFolder: function () { return Promise.resolve(null) }
    },
    conversations: {
      list: function () { return send('listConversations') },
      get: function (id) { return send('getConversation', [id]) },
      create: function () { return send('createConversation') },
      remove: function (id) { return send('deleteConversation', [id]) },
      rename: function (id, title) { return send('renameConversation', [id, title]) }
    },
    agent: {
      send: function (request) { fire('send', [request]) },
      abort: function (id) { fire('abort', [id]) },
      approve: function (callId, approved) { fire('approve', [callId, approved]) },
      onEvent: function (handler) {
        listeners.push(handler)
        return function () {
          var index = listeners.indexOf(handler)
          if (index >= 0) listeners.splice(index, 1)
        }
      }
    },
    window: {
      minimize: function () {},
      toggleMaximize: function () {},
      close: function () {}
    },
    shell: {
      openWorkspace: function () { return Promise.resolve() },
      openExternal: function (url) { fire('openExternal', [url]) }
    }
  }
})()
