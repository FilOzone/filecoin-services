# SessionKeyRegistry

## Usage
Builds with [forge](https://getfoundry.sh/introduction/installation/).

### Build
```sh
forge build
```

### Test
```
forge test -vvv
```

## FAQ

### What are session keys?
Session keys are disposable keys for dapps to perform actions on the user's behalf.
Session keys are scoped to constrain the actions they can take.
Session keys expire in order to reduce the possibilities

### Why a registry?
Certain user actions are not message calls but EIP-712 signatures.
Dapps using `ecrecover` need to check if a session key was authorized to perform an action.
