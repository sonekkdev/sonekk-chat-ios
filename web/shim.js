// Web shim for the Android WebView build. The renderer talks to window.sonekk,
// exactly like it does in Electron, but here the calls land on the Kotlin bridge.
// Installs only when the Electron preload did not provide the real thing.
(function () {
  if (window.sonekk || !window.Native) return

  var listeners = []
  var pending = {}

  window.__sonekkEvent = function (json) {
    var event = JSON.parse(json)
    for (var i = 0; i < listeners.length; i += 1) listeners[i](event)
  }

  function call(name, args) {
    return JSON.parse(window.Native[name].apply(window.Native, args || []))
  }

  function id() {
    return 'id-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8)
  }

  function readFile() {
    return new Promise(function (resolve, reject) {
      var input = document.createElement('input')
      input.type = 'file'
      input.multiple = true
      input.accept = 'image/*,text/*,.md,.json,.csv,.txt,.log,.ts,.js,.kt'
      input.onchange = function () {
        var files = Array.prototype.slice.call(input.files || [])
        Promise.all(
          files.map(function (file) {
            return new Promise(function (done) {
              var reader = new FileReader()
              reader.onload = function () {
                var result = String(reader.result || '')
                var isImage = file.type.indexOf('image/') === 0
                done({
                  name: file.name,
                  mime: file.type || (isImage ? 'image/png' : 'text/plain'),
                  size: file.size,
                  kind: isImage ? 'image' : 'text',
                  data: isImage ? result.split(',')[1] || '' : result
                })
              }
              reader.onerror = function () { done(null) }
              if (file.type.indexOf('image/') === 0) reader.readAsDataURL(file)
              else reader.readAsText(file)
            })
          })
        ).then(function (list) {
          resolve(list.filter(Boolean))
        })
      }
      input.click()
    })
  }

  window.sonekk = {
    settings: {
      get: function () { return Promise.resolve(call('settings')) },
      save: function (patch) { return Promise.resolve(call('saveSettings', [JSON.stringify(patch)])) },
      setKey: function (provider, key) { return Promise.resolve(call('setKey', [provider, key])) },
      test: function (provider) { return Promise.resolve(call('testProvider', [provider])) },
      models: function (provider) { return Promise.resolve(call('models', [provider])) },
      pickFolder: function () { return Promise.resolve(null) }
    },
    conversations: {
      list: function () { return Promise.resolve(call('listConversations')) },
      get: function (conversationId) { return Promise.resolve(call('getConversation', [conversationId])) },
      create: function () { return Promise.resolve(call('createConversation')) },
      remove: function (conversationId) { return Promise.resolve(call('deleteConversation', [conversationId])) },
      rename: function (conversationId, title) { return Promise.resolve(call('renameConversation', [conversationId, title])) }
    },
    agent: {
      send: function (request) { window.Native.send(JSON.stringify(request)) },
      abort: function (conversationId) { window.Native.abort(conversationId) },
      approve: function (callId, approved) { window.Native.approve(callId, approved ? 'true' : 'false') },
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
      openExternal: function (url) { window.Native.openExternal(url) }
    },
    files: {
      pick: readFile
    }
  }
})()
