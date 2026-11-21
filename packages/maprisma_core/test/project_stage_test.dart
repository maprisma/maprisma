import 'package:maprisma_core/src/features/project_stage.dart';
import 'package:test/test.dart';

ProjectState s(
  String status, {
  String phase = 'planning',
  bool valid = false,
  bool stopping = false,
  bool reconcile = false,
  Map? setupReturn,
  String plan = '',
}) => projectState({
  'status': status,
  'phase': phase,
  'needs_reconciliation': reconcile,
  'plan': plan,
  'setup_return': ?setupReturn,
}, ProjectFacts(approvalValid: valid, processesStopping: stopping));

void main() {
  test('stages follow status and phase', () {
    expect(s('draft').stage, ProjectStage.goal);
    expect(s('planning').stage, ProjectStage.plan);
    expect(s('awaiting_review').stage, ProjectStage.approval);
    expect(s('ready', valid: true).stage, ProjectStage.ready);
    expect(s('ready').stage, ProjectStage.approval);
    expect(s('running', phase: 'running').stage, ProjectStage.run);
    expect(
      s('completed', phase: 'running', valid: true).stage,
      ProjectStage.finished,
    );
    for (final status in [
      'reviewing',
      'pausing',
      'paused',
      'interrupted',
      'failed',
    ]) {
      expect(s(status).stage, ProjectStage.plan, reason: '$status in planning');
      expect(
        s(status, phase: 'running').stage,
        ProjectStage.run,
        reason: status,
      );
    }
  });

  test('setup keeps the stage it started from', () {
    final fromReady = s(
      'planning',
      phase: 'setup',
      valid: true,
      setupReturn: {'phase': 'planning', 'status': 'ready'},
    );
    expect(fromReady.stage, ProjectStage.ready);
    expect(fromReady.activity, 'setting_up_team');
    expect(fromReady.bucket, ProjectBucket.running);
    final fromDone = s(
      'planning',
      phase: 'setup',
      valid: true,
      setupReturn: {'phase': 'running', 'status': 'completed'},
    );
    expect(fromDone.stage, ProjectStage.finished);
    // Without setup_return: the core's own fallback.
    expect(s('planning', phase: 'setup').stage, ProjectStage.goal);
    expect(
      s('planning', phase: 'setup', plan: 'A plan.').stage,
      ProjectStage.approval,
    );
  });

  test('a stopped setup keeps its state, not "setting up team"', () {
    final interrupted = s('interrupted', phase: 'setup');
    expect(interrupted.activity, 'interrupted');
    expect(interrupted.bucket, ProjectBucket.attention);
    final paused = s('paused', phase: 'setup');
    expect(paused.activity, 'paused');
    expect(paused.bucket, ProjectBucket.needsYou);
  });

  test('stopping wins the label and the bucket', () {
    for (final status in ['interrupted', 'ready', 'completed', 'paused']) {
      final state = s(
        status,
        phase: 'running',
        stopping: true,
        reconcile: true,
      );
      expect(state.activity, 'stopping', reason: status);
      expect(state.bucket, ProjectBucket.running, reason: status);
    }
    final pausing = s('pausing', phase: 'setup', reconcile: true);
    expect(pausing.activity, 'stopping');
    expect(pausing.bucket, ProjectBucket.running);
  });

  test('reconciliation is a second line, never hiding the state', () {
    final paused = s('paused', phase: 'running', reconcile: true, valid: true);
    expect(paused.activity, 'paused');
    expect(paused.second, 'check_changes_first');
    expect(paused.bucket, ProjectBucket.needsYou);
    final failed = s('failed', phase: 'running', reconcile: true);
    expect(failed.activity, 'failed');
    expect(failed.second, 'check_changes_first');
    expect(failed.bucket, ProjectBucket.attention);
    // A draft edited from an interrupted run stays a draft.
    final draft = s('draft', reconcile: true);
    expect(draft.bucket, ProjectBucket.drafts);
    expect(draft.second, 'check_changes_first');
    final ready = s('ready', reconcile: true, valid: true);
    expect(ready.bucket, ProjectBucket.needsYou);
    // On the wire in snake case, like the summary's keys.
    expect(ready.toJson()['bucket'], 'needs_you');
  });

  test(
    'approval: invalid where a run needs it, never for drafts or planning',
    () {
      expect(s('draft').bucket, ProjectBucket.drafts);
      expect(s('planning').bucket, ProjectBucket.running);
      final stale = s('ready');
      expect(stale.activity, 'approve_again');
      expect(stale.bucket, ProjectBucket.needsYou);
      final stoppedRun = s('interrupted', phase: 'running');
      expect(stoppedRun.stage, ProjectStage.run);
      expect(stoppedRun.second, 'approve_again');
      expect(stoppedRun.bucket, ProjectBucket.attention);
      final ok = s('ready', valid: true);
      expect(ok.activity, 'ready_to_run');
      expect(ok.bucket, ProjectBucket.ready);
      expect(ok.second, isNull);
    },
  );

  test('a completed project stays finished', () {
    final done = s('completed', phase: 'running', valid: true);
    expect(done.activity, 'agents_finished');
    expect(done.bucket, ProjectBucket.finished);
    // Its approval going stale later does not make it "need you".
    expect(s('completed', phase: 'running').bucket, ProjectBucket.finished);
  });

  test('awaiting review needs you; every project lands in one bucket', () {
    expect(s('awaiting_review').bucket, ProjectBucket.needsYou);
    expect(s('awaiting_review').activity, 'needs_review');
    for (final status in [
      'draft',
      'planning',
      'awaiting_review',
      'ready',
      'running',
      'reviewing',
      'pausing',
      'paused',
      'interrupted',
      'failed',
      'completed',
    ]) {
      for (final phase in ['planning', 'running', 'setup']) {
        final state = s(status, phase: phase);
        expect(ProjectBucket.values, contains(state.bucket));
        expect(state.toJson().keys, ['stage', 'activity', 'second', 'bucket']);
      }
    }
  });
}
