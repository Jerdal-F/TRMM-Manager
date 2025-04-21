# TRMM Manager IOS App

TRMM Manager IOS is a Swift-based application designed to manage Tactical RMM agents. This app provides functionalities such as viewing agent details, sending commands, and managing agent processes.

## Features

- **Agent Management**: View and manage Tactical RMM agents.
- **API Integration**: Fetch agent details and history from the Tactical RMM server.
- **Command Execution**: Send commands to agents and view the output.
- **Process Management**: View and kill processes running on agents.
- **Diagnostic Logging**: Log and export diagnostic information.
- **Keychain Integration**: Securely store and retrieve API keys.

## Requirements

- iOS 14.0+
- Xcode 12.0+
- Swift 5.3+

## Usage

1. Launch the app on your iOS device.
2. Enter the API URL and API Key in the settings section.
3. Tap "Save & Login" to authenticate and fetch agent details.
4. Use the navigation to view agent details, send commands, and manage processes.

## Logging

The app includes a `DiagnosticLogger` class for logging diagnostic information. Logs are saved to a file in the app's document directory and can be exported for troubleshooting. To save the logs, hold the TRMM Manager text for a few seconds to get a prompt to save the logs.


## Keychain

The app uses `KeychainHelper` to securely store and retrieve the API key.


## License

This project is licensed under the **Business Source License 1.1**. See the [LICENSE](LICENSE) file for details.
