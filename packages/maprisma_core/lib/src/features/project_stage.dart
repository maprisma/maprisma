/// Where a project is and what it does now, derived from its stored record
/// (docs/plan-main-layout.md, "Status, stages and filters"). Pure: the header
/// counts, the board and the filters all use this one function.
library;

/// The stage on the rail.
enum ProjectStage { goal, plan, approval, ready, run, finished }

/// The filter a project counts in; mutually exclusive, checked in this order.
enum ProjectBucket {
  running('running'),
  attention('attention'),
  needsYou('needs_you'),
  ready('ready'),
  drafts('drafts'),
  finished('finished');

  const ProjectBucket(this.code);

  /// The machine code on the wire (snake case, like the summary's keys).
  final String code;
}

/// What the core knows besides the record itself.
final class ProjectFacts {
  const ProjectFacts({
    this.approvalValid = false,
    this.processesStopping = false,
    this.launchBlocked = false,
  });

  /// The approval matches the plan, the teams and the launch facts now.
  final bool approvalValid;

  /// A supervisor still owns processes of this project (also after a
  /// restart that restored another status).
  final bool processesStopping;

  /// A valid approval whose launch would fail now (a stopped runtime, a
  /// model it no longer serves, a missing folder; the launch's own checks):
  /// fixing it needs no new approval.
  final bool launchBlocked;
}

/// The derived view of one project; all values are stable machine codes.
final class ProjectState {
  const ProjectState(this.stage, this.activity, this.second, this.bucket);
  final ProjectStage stage;

  /// The activity label's code (see [projectState]).
  final String activity;

  /// What is required next without hiding the state, or null.
  final String? second;
  final ProjectBucket bucket;

  /// The board projection's form.
  Map<String, Object?> toJson() => {
    'stage': stage.name,
    'activity': activity,
    'second': second,
    'bucket': bucket.code,
  };
}

const _stopped = {'reviewing', 'pausing', 'paused', 'interrupted', 'failed'};

ProjectStage _stage(
  String status,
  String phase,
  Map record,
  bool approvalValid,
) {
  if (phase == 'setup') {
    // The stage the team setup started from; without one the core's own
    // fallback: Goal when there is no plan yet, else Approval.
    final back = record['setup_return'];
    final from = back is Map ? back['status'] : null;
    final fromPhase = back is Map ? back['phase'] : null;
    if (from is String && fromPhase is String && fromPhase != 'setup') {
      return _stage(from, fromPhase, {'plan': record['plan']}, approvalValid);
    }
    final plan = record['plan'];
    return plan is String && plan.trim().isNotEmpty
        ? ProjectStage.approval
        : ProjectStage.goal;
  }
  if (status == 'draft') return ProjectStage.goal;
  if (status == 'planning') return ProjectStage.plan;
  if (status == 'awaiting_review') return ProjectStage.approval;
  if (status == 'ready') {
    return approvalValid ? ProjectStage.ready : ProjectStage.approval;
  }
  if (status == 'running') return ProjectStage.run;
  if (status == 'completed') return ProjectStage.finished;
  if (_stopped.contains(status)) {
    return phase == 'running' ? ProjectStage.run : ProjectStage.plan;
  }
  return ProjectStage.goal;
}

/// The stage, activity label, second line and filter bucket of [record].
ProjectState projectState(Map record, ProjectFacts facts) {
  final status = '${record['status'] ?? 'draft'}';
  final phase = '${record['phase'] ?? 'planning'}';
  final reconcile = record['needs_reconciliation'] == true;
  final stage = _stage(status, phase, record, facts.approvalValid);
  final stopping = status == 'pausing' || facts.processesStopping;
  final activeSetup = phase == 'setup' && status == 'planning';
  final stoppedRun =
      phase == 'running' &&
      const {'paused', 'interrupted', 'failed'}.contains(status);
  final approveAgain =
      !facts.approvalValid && (status == 'ready' || stoppedRun);
  final blocked =
      status == 'ready' && facts.approvalValid && facts.launchBlocked;

  final activity = stopping
      ? 'stopping'
      : activeSetup
      ? 'setting_up_team'
      : switch (status) {
          'planning' => 'planning',
          'reviewing' => phase == 'running' ? 'reviewing' : 'reviewing_plan',
          'running' => 'running',
          'paused' => 'paused',
          'interrupted' => 'interrupted',
          'failed' => 'failed',
          'awaiting_review' => 'needs_review',
          'ready' =>
            !facts.approvalValid
                ? 'approve_again'
                : blocked
                ? 'approved_blocked'
                : 'ready_to_run',
          'completed' => 'agents_finished',
          _ => 'draft',
        };

  // The second line: what is required next, without hiding the state.
  final second = reconcile
      ? 'check_changes_first'
      : approveAgain && activity != 'approve_again'
      ? 'approve_again'
      : null;

  final ProjectBucket bucket;
  if (stopping ||
      activeSetup ||
      const {'planning', 'running', 'reviewing'}.contains(status)) {
    bucket = ProjectBucket.running;
  } else if (status == 'interrupted' || status == 'failed') {
    bucket = ProjectBucket.attention;
  } else if (status == 'awaiting_review' ||
      status == 'paused' ||
      (reconcile && (status == 'ready' || status == 'completed')) ||
      approveAgain ||
      blocked) {
    bucket = ProjectBucket.needsYou;
  } else if (status == 'ready') {
    bucket = ProjectBucket.ready;
  } else if (status == 'completed') {
    bucket = ProjectBucket.finished;
  } else {
    bucket = ProjectBucket.drafts;
  }
  return ProjectState(stage, activity, second, bucket);
}
