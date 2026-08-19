// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * Test-only stand-ins for the Ritual Chain system contracts and precompiles.
 *
 * Tests deploy these contracts and then `vm.etch` their runtime bytecode at the
 * canonical Ritual addresses (see RitualChain.sol), so RitualPredict runs against
 * the real addresses while the behaviour is fully local and deterministic:
 *
 *   vm.etch(RitualChain.SCHEDULER, address(new MockScheduler()).code);
 *   vm.etch(RitualChain.RITUAL_WALLET, address(new MockRitualWallet()).code);
 *   vm.etch(RitualChain.TEE_SERVICE_REGISTRY, address(new MockTEEServiceRegistry()).code);
 *   vm.etch(RitualChain.HTTP_PRECOMPILE, address(new MockHTTPPrecompile()).code);
 *   vm.etch(RitualChain.JQ_PRECOMPILE, address(new MockJQPrecompile()).code);
 *
 * IMPORTANT: after `vm.etch`, the canonical address keeps its own storage. To
 * configure a mock, cast the canonical address and call it, e.g.
 * `MockHTTPPrecompile(RitualChain.HTTP_PRECOMPILE).setResponse(...)` — configuring
 * the originally-deployed instance would write to a different account's storage.
 */

/// Scheduler stand-in: records every schedule/cancel and lets tests replay the
/// callback exactly the way the real Scheduler would (msg.sender = canonical addr).
contract MockScheduler {
    event Scheduled(
        bytes data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    );
    event Cancelled(uint256 callId);

    // No constructor initializer on purpose: the mock is used via vm.etch at the
    // canonical address, where the constructor never runs. nextCallId starts at 0
    // in empty storage, so `++nextCallId` yields 1 on the first schedule.
    uint256 public nextCallId;
    uint256 public lastCallId;
    uint256 public cancelCount;
    bytes public lastData;
    uint32 public lastStartBlock;
    uint32 public lastNumCalls;
    uint32 public lastFrequency;

    function schedule(
        bytes calldata data,
        uint32 gas,
        uint32 startBlock,
        uint32 numCalls,
        uint32 frequency,
        uint32 ttl,
        uint256 maxFeePerGas,
        uint256 maxPriorityFeePerGas,
        uint256 value,
        address payer
    ) external returns (uint256 callId) {
        callId = ++nextCallId;
        lastCallId = callId;
        lastData = data;
        lastStartBlock = startBlock;
        lastNumCalls = numCalls;
        lastFrequency = frequency;
        emit Scheduled(
            data,
            gas,
            startBlock,
            numCalls,
            frequency,
            ttl,
            maxFeePerGas,
            maxPriorityFeePerGas,
            value,
            payer
        );
    }

    function cancel(uint256) external {
        cancelCount++;
        emit Cancelled(cancelCount);
    }

    function getCallState(uint256) external pure returns (uint8) {
        return 2; // COMPLETED
    }

    function approveScheduler(address) external {}
}

/// RitualWallet stand-in: keeps per-account balances and lock heights.
contract MockRitualWallet {
    event Deposited(address indexed account, uint256 amount, uint256 lockDuration);

    mapping(address => uint256) public balances;
    mapping(address => uint256) public lockUntils;

    function deposit(uint256 lockDuration) external payable {
        balances[msg.sender] += msg.value;
        lockUntils[msg.sender] = block.number + lockDuration;
        emit Deposited(msg.sender, msg.value, lockDuration);
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function lockUntil(address account) external view returns (uint256) {
        return lockUntils[account];
    }
}

/// TEEServiceRegistry stand-in: returns the configured executor (or none).
/// The real function is `view` and reached via staticcall, so this mock must
/// stay side-effect-free too.
contract MockTEEServiceRegistry {
    address public executor;
    bool public found = true;

    function setExecutor(address executor_, bool found_) external {
        executor = executor_;
        found = found_;
    }

    function pickServiceByCapability(
        uint8,
        bool,
        uint256,
        uint256
    ) external view returns (address teeAddress, bool found_) {
        return (executor, found);
    }
}

/// HTTP precompile (0x0801) stand-in. The real precompile is not a contract, so
/// `RitualPredict` reaches it with a raw `.call` whose calldata is the 13-field
/// abi.encode — the first 4 bytes are not a selector. The mock serves that raw
/// shape from its fallback and returns the short-running-async envelope
/// `(bytes simmedInput, bytes actualOutput)`.
///
/// NOTE: decoding all 13 fields with one abi.decode is avoided on purpose —
/// solc 0.8.28 miscompiles such large dynamic decodes at optimizer runs=200
/// (bare 13-tuple decode = stack-too-deep at compile; struct decode reverts at
/// runtime). Head slots are read directly from calldata instead.
contract MockHTTPPrecompile {
    event HttpRequested(
        address executor,
        uint256 ttl,
        string url,
        uint8 method,
        uint256 inputLength
    );

    uint16 public status = 200;
    bytes public body = "{\"price\": 4200}";
    string public errorMessage = "";
    bool public revertCall = false;
    uint256 public requestCount;
    /// When non-empty, the fallback returns this verbatim — simulates a malformed
    /// envelope from the chain so tests can exercise the decode-catch path.
    bytes public rawOverride;

    function setResponse(
        uint16 status_,
        bytes calldata body_,
        string calldata errorMessage_
    ) external {
        status = status_;
        body = body_;
        errorMessage = errorMessage_;
    }

    function setRevertCall(bool revert_) external {
        revertCall = revert_;
    }

    function setRawOverride(bytes calldata raw_) external {
        rawOverride = raw_;
    }

    /// Reads the n-th 32-byte head slot of the request tuple.
    function _head(bytes calldata input, uint256 slot) private pure returns (bytes32 value) {
        assembly {
            value := calldataload(add(input.offset, mul(slot, 32)))
        }
    }

    /// Reads a string whose data (length word + content) starts at `offset`
    /// inside the request calldata. Pure assembly on purpose: abi.decode on
    /// calldata slices miscompiles under solc 0.8.28 / optimizer runs=200.
    function _calldataString(
        bytes calldata input,
        uint256 offset
    ) private pure returns (string memory out) {
        uint256 len;
        assembly {
            len := calldataload(add(input.offset, offset))
        }
        out = new string(len);
        assembly {
            calldatacopy(add(out, 32), add(input.offset, add(offset, 32)), len)
        }
    }

    fallback(bytes calldata input) external returns (bytes memory) {
        // 13-field HTTP request layout (head slots):
        //   0 executor, 1 encryptedSecrets, 2 ttl, 3 secretSignatures,
        //   4 userPublicKey, 5 url, 6 method, 7 headerKeys, 8 headerValues,
        //   9 body, 10 dkmsKeyIndex, 11 dkmsKeyFormat, 12 piiEnabled
        address executor = address(uint160(uint256(_head(input, 0))));
        uint256 ttl = uint256(_head(input, 2));
        string memory url = _calldataString(input, uint256(_head(input, 5)));
        uint8 method = uint8(uint256(_head(input, 6)));

        requestCount++;
        emit HttpRequested(executor, ttl, url, method, input.length);

        if (revertCall) revert("mock http precompile failure");
        if (rawOverride.length > 0) return rawOverride;

        // The settled envelope: simmedInput is empty for a real executor run,
        // actualOutput carries the 5-field HTTP response.
        bytes memory actualOutput = abi.encode(
            status,
            new string[](0),
            new string[](0),
            body,
            errorMessage
        );
        return abi.encode(bytes(""), actualOutput);
    }
}

/// jq precompile (0x0803) stand-in. Called via staticcall with
/// abi.encode(query, json, outputType); returns abi.encode(uint256) — or empty
/// bytes when configured to fail (the length check in _jqUint is load-bearing).
contract MockJQPrecompile {
    uint256 public value;
    bool public ok = true;

    function setResult(uint256 value_, bool ok_) external {
        value = value_;
        ok = ok_;
    }

    // Non-view so it can return data (0.8.28 forbids view fallbacks that return);
    // it never writes state, so calling it via staticcall from _jqUint is safe.
    fallback(bytes calldata) external returns (bytes memory) {
        if (!ok) return bytes("");
        return abi.encode(value);
    }
}
