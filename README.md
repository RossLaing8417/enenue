# enenue

Reinventing the wheel

## TODO:

### Arguments
- runtime-dir: Directory of the runtime scripts (defaults to ./runtime)
- config-file: Config json file containing the integrations to enable
- log-level: Different log levels (TODO: define the levels, possible split server logging from integration logging)

### Verify config json
- Accept config file
- Verify and print result
- Exit

### Server start:
- Read json config file (runtime arg)
- Create endpoints & tasks from config
- Run indefinately

### Endpoints:
- Start lua
- Initialize global enenue state
- Initialize endpoint state
- Forward request
- Accept and forward response

### Task (Poll directory):
- Start lua
- Initialize global enenue state
- Initialize endpoint state
- Forward file contents

### Task (Poll endpoint):
- Start lua
- Initialize enenue state
- Initialize endpoint state
- Read request and forward response

### Notes:
- New lua state per action (for now, persisting states can happen later if slow)
- Zig code to read from lua endpoint but handle heavy lifting
