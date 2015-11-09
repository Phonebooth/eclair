eclair
======
Erlang Config Layer. __eclair__ is an escript that merges Erlang config stored
in a well-defined hierarchy of S3 paths.

Getting started
---------------
These steps will get eclair set up to pull config from an S3 path.
```bash
make build
cp eclair.tar ~/path/to/myapp && cd ~/path/to/myapp
tar xfv eclair.tar
./eclair.erl bootstrap
```

Note: Your S3 credentials will be stored in __.eclair/secure.config__.

Uploading config
----------------
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
__s3://${ECLAIR_ROOT}/myapp/root/myapp.config__.

Next, our app has a config element specific to a QA environment.
We'll upload the following files to 
__s3://${ECLAIR_ROOT}/myapp/env/qa/myapp.config__.

```Erlang
[
    {myapp, [
        {password, "myQApassword"}
    ]}
].
```

And PROD config to
__s3://${ECLAIR_ROOT}/myapp/env/pro/myapp.config__.

```Erlang
[
    {myapp, [
        {password, "myPRODpassword"}
    ]}
].
```

When __myapp__ is deployed, the deploy script must run

```bash
./eclair.erl -tags env/qa
```

__eclair__ will check the following locations (in order) for config
```bash
    1. ${ECLAIR_ROOT/myapp/root
[2-n]. ${ECLAIR_ROOT/myapp/{tag}
  n+1. ${ECLAIR_ROOT/myapp/host/{hostname}
```
