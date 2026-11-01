# Sonekks Chat for iOS

The same Sonekks Chat UI, running on iPhone as a WKWebView app with a native Swift bridge.

Built for jailbroken devices: the CI produces an **unsigned IPA**, which you sign and install with kSign, TrollStore or AltStore.

## What works

- identical interface to the desktop and Android builds, same components and CSS
- Anthropic, DeepSeek, Google and OpenRouter, streaming with tool calling
- API keys in the Keychain, conversations in the app sandbox
- attachments, effort levels, token and cost meters, history, approvals
- file tools inside the app sandbox

## What does not work

- **`run_command` returns an error.** iOS has no shell inside an app sandbox, so the agent is file only.
- No live model list. You type the model name in settings.
- Not tested on a device by the author, there is no Mac in the build environment. CI compiles it.

## Build

There is no macOS here, so the IPA is built by GitHub Actions:

1. Push to the repo, the `ios` workflow runs on `macos-14`
2. Download the `SonekkChat-ipa` artifact
3. Sign it with kSign and install

The web bundle is inlined into a single HTML file by `make-ios-bundle.mjs`, because WKWebView cannot load ES modules from `file://`. Regenerate it after changing the UI:

```bash
node make-ios-bundle.mjs
```

## Layout

```
ios/              Swift sources: web view, bridge, store, providers, agent
web/              web bundle copied from the desktop renderer
web-ios/          generated single file HTML
project.yml       XcodeGen spec, no .xcodeproj in the repo
```

## License

PolyForm Noncommercial 1.0.0, same as Sonekks Chat.

Required Notice: Copyright 2026 sonekkdev (https://github.com/sonekkdev/sonekk-chat-ios)
