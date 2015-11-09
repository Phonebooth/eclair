# eclair
Erlang Config Layer. __eclair__ is an escript that merges Erlang config stored
in a well-defined hierarchy of S3 paths.

## Getting started
These steps will get eclair set up to pull config from an S3 path.
```bash
make build
cp eclair.tar ~/path/to/myapp && cd ~/path/to/myapp
tar xfv eclair.tar
./eclair.erl bootstrap -version auto
```

Note: Your S3 credentials will be stored in `.eclair/secure.config`.

## Uploading config
__eclair__ is able to merge together standard Erlang proplist config files.
Here's an example:

```Erlang
[
    {myapp, [
        {config_item, "Hi!"}
    ]}
].
```

We'll consider this file our root config and upload it to
`s3://${ECLAIR_ROOT}/myapp/root/myapp.config`.

Next, our app has a config element specific to a QA environment.
We'll upload the following files to 
`s3://${ECLAIR_ROOT}/myapp/env/qa/myapp.config`.

```Erlang
[
    {myapp, [
        {password, "myQApassword"}
    ]}
].
```

And PROD config to
`s3://${ECLAIR_ROOT}/myapp/env/pro/myapp.config`.

```Erlang
[
    {myapp, [
        {password, "myPRODpassword"}
    ]}
].
```

When `myapp` is deployed, the deploy script must run

```bash
./eclair.erl -tags env/qa
```

The final config will contain this data:
```Erlang
[
    {myapp, [
        {config_item, "Hi!"},
        {password, "myQApassword"}
    ]}
].
```

## Order of Operations
### bootstrap
1. Read command line arguments
2. Read from `.eclair/secure.config`
3. Read from `~/.s3cfg` (`access_key` and `secret_key` only)
4. Read from input prompt
5. Write `.eclair/secure.config`
### main
#### Setup
1. Read command lien arguments
2. Read from `.eclair/secure.config`
3. Read from hardcoded values in `eclair.erl` macros
#### Gather data
1. Get list of nodes from epmd
2. Get hostname
3. Find application details in an `ebin/*.app` file
#### Build S3 paths
1. Append application name from `*.app` file to eclair root
2. List s3 common prefixes for the `version` subkey
3. Find existing version-root that is closest to the version input. (if none, this step is skipped)
4. Search for config with these subkeys: `root`, `input/tag1`, `input/tag2`, `epmd/node1`, `epmd/node2`, `host/this-host`
#### For each path, merge config
1. List all keys at this path
2. Create subdirectories as needed
3. If new file, `get` the file directly
4. If existing file, attempt a `file:consult` on both, and merge
5. If `consult` fails, overwrite existing file
