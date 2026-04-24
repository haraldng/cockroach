// Copyright 2025 The Cockroach Authors.
//
// Use of this software is governed by the CockroachDB Software License
// included in the /LICENSE file.

package logstore

import (
	"context"
	"fmt"
	"math"
	"path/filepath"
	"strings"
	"testing"

	"github.com/cockroachdb/cockroach/pkg/keys"
	"github.com/cockroachdb/cockroach/pkg/kv/kvpb"
	"github.com/cockroachdb/cockroach/pkg/kv/kvserver/kvserverpb"
	"github.com/cockroachdb/cockroach/pkg/kv/kvserver/print"
	"github.com/cockroachdb/cockroach/pkg/raft"
	"github.com/cockroachdb/cockroach/pkg/raft/raftpb"
	"github.com/cockroachdb/cockroach/pkg/roachpb"
	"github.com/cockroachdb/cockroach/pkg/settings/cluster"
	"github.com/cockroachdb/cockroach/pkg/storage"
	"github.com/cockroachdb/cockroach/pkg/storage/fs"
	"github.com/cockroachdb/cockroach/pkg/testutils/echotest"
	"github.com/stretchr/testify/require"
	"golang.org/x/time/rate"
)

func TestRaftStorageWrites(t *testing.T) {
	ctx := context.Background()
	const rangeID = roachpb.RangeID(123)
	sl := NewStateLoader(rangeID)
	eng := storage.NewDefaultInMemForTesting()
	defer eng.Close()

	trunc := kvserverpb.RaftTruncatedState{Index: 100, Term: 20}
	state := RaftState{LastIndex: trunc.Index, LastTerm: trunc.Term}
	var output string

	printCommand := func(name, batch string) {
		output += fmt.Sprintf(">> %s\n%s\nState:%+v RaftTruncatedState:%+v\n",
			name, batch, state, trunc)
	}
	printCommand("init", "")

	writeBatch := func(prepare func(rw storage.ReadWriter)) string {
		t.Helper()
		batch := eng.NewBatch()
		defer batch.Close()
		prepare(batch)
		wb := kvserverpb.WriteBatch{Data: batch.Repr()}
		str, err := print.DecodeWriteBatch(wb.GetData())
		require.NoError(t, err)
		require.NoError(t, batch.Commit(true))
		return str
	}
	stats := func() int64 {
		t.Helper()
		prefix := keys.RaftLogPrefix(rangeID)
		prefixEnd := prefix.PrefixEnd()
		ms, err := storage.ComputeStats(ctx, eng, fs.ReplicationReadCategory,
			prefix, prefixEnd, 0 /* nowNanos */)
		require.NoError(t, err)
		return ms.SysBytes
	}

	write := func(name string, hs raftpb.HardState, entries []raftpb.Entry) {
		t.Helper()
		var newState RaftState
		batch := writeBatch(func(rw storage.ReadWriter) {
			require.NoError(t, storeHardState(ctx, rw, sl, hs))
			var err error
			newState, err = logAppend(ctx, sl.RaftLogPrefix(), rw, state, entries)
			require.NoError(t, err)
		})
		state = newState
		require.Equal(t, stats(), state.ByteSize)
		printCommand(name, batch)
	}
	truncate := func(name string, ts kvserverpb.RaftTruncatedState) {
		t.Helper()
		batch := writeBatch(func(rw storage.ReadWriter) {
			require.NoError(t, Compact(ctx, trunc, ts, sl, rw))
		})
		trunc = ts
		state.ByteSize = stats()
		printCommand(name, batch)
	}

	write("append (100,103]", raftpb.HardState{
		Term: 21, Vote: 3, Commit: 100, Lead: 3, LeadEpoch: 5,
	}, []raftpb.Entry{
		{Index: 101, Term: 20},
		{Index: 102, Term: 21},
		{Index: 103, Term: 21},
	})
	write("append (101,102] with overlap", raftpb.HardState{
		Term: 22, Commit: 100,
	}, []raftpb.Entry{
		{Index: 102, Term: 22},
	})
	write("append (102,105]", raftpb.HardState{}, []raftpb.Entry{
		{Index: 103, Term: 22},
		{Index: 104, Term: 22},
		{Index: 105, Term: 22},
	})
	truncate("truncate at 103", kvserverpb.RaftTruncatedState{Index: 103, Term: 22})
	truncate("truncate all", kvserverpb.RaftTruncatedState{Index: 105, Term: 22})

	// TODO(pav-kv): print the engine content as well.

	output = strings.ReplaceAll(output, "\n\n", "\n")
	output = strings.ReplaceAll(output, "\n\n", "\n")
	echotest.Require(t, output, filepath.Join("testdata", t.Name()+".txt"))
}

// countingSyncCallback records how many times OnLogSync was invoked. Used by
// TestSimulatedWALWriteSkip to verify that skipped-write appends still ack
// durability back to Raft.
type countingSyncCallback struct {
	n int
}

func (c *countingSyncCallback) OnLogSync(context.Context, raft.StorageAppendAck, WriteStats) {
	c.n++
}

// TestSimulatedWALWriteSkip exercises the design-(2) simulation knob
// SimulatedWALWriteSkipProbability. With probability 1.0, non-overwriting
// appends must not write any entry bytes to the engine, while the in-memory
// RaftState still advances and the sync callback still fires. Overwriting
// appends must never be skipped.
func TestSimulatedWALWriteSkip(t *testing.T) {
	ctx := context.Background()
	const rangeID = roachpb.RangeID(42)

	// raftLogBytes returns the bytes in the engine that belong to this
	// range's raft log. It is 0 when no entries have been persisted.
	raftLogBytes := func(t *testing.T, eng storage.Engine) int64 {
		t.Helper()
		prefix := keys.RaftLogPrefix(rangeID)
		ms, err := storage.ComputeStats(ctx, eng, fs.ReplicationReadCategory,
			prefix, prefix.PrefixEnd(), 0 /* nowNanos */)
		require.NoError(t, err)
		return ms.SysBytes
	}

	// newLogStore builds an in-memory LogStore with non-blocking sync
	// disabled (so storeEntriesAndCommitBatch takes the blocking path and we
	// don't need a SyncWaiterLoop). The caller must close the engine.
	newLogStore := func(t *testing.T) (*LogStore, storage.Engine) {
		t.Helper()
		eng := storage.NewDefaultInMemForTesting()
		st := cluster.MakeTestingClusterSettings()
		enableNonBlockingRaftLogSync.Override(ctx, &st.SV, false)
		sideload := NewDiskSideloadStorage(
			st, 1,
			filepath.Join(eng.GetAuxiliaryDir(), "fake", "testing", "dir"),
			rate.NewLimiter(rate.Inf, math.MaxInt64), eng.Env())
		return &LogStore{
			RangeID:     rangeID,
			Engine:      eng,
			Sideload:    sideload,
			StateLoader: NewStateLoader(rangeID),
			Settings:    st,
		}, eng
	}

	// makeAppend builds a non-empty StorageAppend for the given (index, term)
	// pair, with a MsgAppResp response so MustSync() returns true.
	makeAppend := func(index, term uint64, commit uint64) raft.StorageAppend {
		return raft.StorageAppend{
			HardState: raftpb.HardState{Term: term, Commit: commit},
			Entries:   []raftpb.Entry{{Index: index, Term: term}},
			Responses: []raftpb.Message{{Type: raftpb.MsgAppResp}},
		}
	}

	t.Run("skip=1.0 drops all non-overwriting writes", func(t *testing.T) {
		s, eng := newLogStore(t)
		defer eng.Close()
		SimulatedWALWriteSkipProbability.Override(ctx, &s.Settings.SV, 1.0)

		cb := &countingSyncCallback{}
		rs := RaftState{LastTerm: 1}
		stats := &AppendStats{}

		const N = 10
		for i := uint64(1); i <= N; i++ {
			var err error
			rs, err = s.StoreEntries(ctx, rs, makeAppend(i, 1, i), cb, stats)
			require.NoError(t, err)
		}

		require.Equal(t, kvpb.RaftIndex(N), rs.LastIndex)
		require.Equal(t, kvpb.RaftTerm(1), rs.LastTerm)
		require.Zero(t, raftLogBytes(t, eng),
			"no entry bytes should reach the engine when skip probability is 1.0")
		require.Equal(t, N, cb.n,
			"OnLogSync should fire once per append with MustSync")
	})

	t.Run("skip=0.0 writes normally", func(t *testing.T) {
		s, eng := newLogStore(t)
		defer eng.Close()
		// Leave SimulatedWALWriteSkipProbability at the default (0).

		cb := &countingSyncCallback{}
		rs := RaftState{LastTerm: 1}
		stats := &AppendStats{}

		var err error
		rs, err = s.StoreEntries(ctx, rs, makeAppend(1, 1, 1), cb, stats)
		require.NoError(t, err)
		require.Equal(t, kvpb.RaftIndex(1), rs.LastIndex)
		require.Positive(t, raftLogBytes(t, eng),
			"entry bytes should reach the engine when skip probability is 0")
	})

	t.Run("overwriting appends are never skipped", func(t *testing.T) {
		s, eng := newLogStore(t)
		defer eng.Close()

		// First, write index=1 at term=1 normally.
		cb := &countingSyncCallback{}
		rs := RaftState{LastTerm: 1}
		stats := &AppendStats{}
		var err error
		rs, err = s.StoreEntries(ctx, rs, makeAppend(1, 1, 1), cb, stats)
		require.NoError(t, err)

		// Verify the entry is stored with term=1.
		entry, err := LoadEntry(ctx, eng, rangeID, 1)
		require.NoError(t, err)
		require.Equal(t, uint64(1), entry.Term)

		// Now enable maximum skip probability and overwrite index=1 with term=2.
		// The overwriting path must ignore the skip knob and persist the new
		// entry; otherwise sideloaded files could be purged while the log still
		// logically contains them.
		SimulatedWALWriteSkipProbability.Override(ctx, &s.Settings.SV, 1.0)
		_, err = s.StoreEntries(ctx, rs, makeAppend(1, 2, 1), cb, stats)
		require.NoError(t, err)

		entry, err = LoadEntry(ctx, eng, rangeID, 1)
		require.NoError(t, err)
		require.Equal(t, uint64(2), entry.Term,
			"overwriting append must be written even when skip probability is 1.0")
	})
}
