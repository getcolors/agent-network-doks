from pathlib import Path
import inspect
import pytest
from blue.workflow import run, workflow as make_workflow
from package_agent_network_doks_blue import workflow, tools


@pytest.mark.asyncio
async def test_retired_routes_only_to_idempotent_local_cleanup(tmp_path):
    opts = {'profile': 'retired', 'workdir': str(tmp_path), 'blue/event': 'delete'}
    paths = [Path(tools.kubeconfig_path(opts)), Path(tools.state_dir(opts)) / 'leftover', Path(tools.profile_dir(opts)) / 'proofs/leftover']
    paths.append(Path(tools.lego_dir(opts)) / 'accounts/private-key')
    for path in paths:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text('synthetic leftover')
    keep = tmp_path / 'keep'; keep.write_text('not a generated target')
    seen = []
    inspection_exit = 0
    def wire(step, current):
        if step == 'agent-network-doks/start':
            return (lambda o: (seen.append(step) or {**o, 'blue/exit': 0}), 'agent-network-doks/load-managed')
        if step == 'agent-network-doks/load-managed':
            return (lambda o: (seen.append(step) or {**o, 'blue/exit': inspection_exit, 'managed/already-destroyed': True}), 'forbidden/remote')
        if step == 'agent-network-doks/cleanup':
            async def local(o):
                seen.append(step)
                result = workflow.wire_fn(step, o)[0](o)
                return await result if inspect.isawaitable(result) else result
            return (local,)
        def forbidden(o):
            raise AssertionError('remote stage executed')
        return (forbidden,)
    native = make_workflow(start='agent-network-doks/start', wire_fn=wire, next_fn=workflow.next_steps)
    for _ in range(2):
        seen.clear()
        result = await run(native, opts)
        assert result['blue/exit'] == 0
        assert seen == ['agent-network-doks/start', 'agent-network-doks/load-managed', 'agent-network-doks/cleanup']
        assert not any(path.exists() for path in paths)
        assert keep.read_text() == 'not a generated target'
    inspection_exit = 1
    seen.clear()
    assert (await run(native, opts))['blue/exit'] == 1
    assert seen == ['agent-network-doks/start', 'agent-network-doks/load-managed']
    assert workflow.next_steps('agent-network-doks/load-managed', ['forbidden/remote'], {**opts, 'blue/exit': 1, 'managed/already-destroyed': True}) == []
    assert not (tmp_path / '.ssh').exists()
