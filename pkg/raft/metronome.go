package raft

// NodeId is a type alias for node identifiers

// Metronome struct to hold state
type Metronome struct {
	// Id of this node
	Pid                int
	MyCriticalOrdering []bool
	CriticalLen        int
	TotalLen           int
	Ratio              float64
}

// QuorumTuple is a type alias for a slice of NodeIds
type QuorumTuple []int

// MaximizeDistanceOrdering reorders quorums to maximize the Distance between consecutive ones
func MaximizeDistanceOrdering(tuples *[]QuorumTuple) []QuorumTuple {
	orderedTuples := []QuorumTuple{(*tuples)[0]}
	*tuples = (*tuples)[1:] // Remove first element

	// Map to keep track of the occurrences of each node
	nodeOccurrences := make(map[int]int)

	// Update node occurrences for the initial tuple
	for _, node := range orderedTuples[0] {
		nodeOccurrences[node]++
	}

	for len(*tuples) > 0 {
		// All quorums have common nodes, pick the one with max distance
		var maxDist = -1
		var candidates []QuorumTuple

		for _, tuple := range *tuples {
			currentTuple := orderedTuples[len(orderedTuples)-1]
			distance := Distance(currentTuple, tuple)
			if distance > maxDist {
				maxDist = distance
				candidates = []QuorumTuple{tuple}
			} else if distance == maxDist {
				candidates = append(candidates, tuple)
			}
		}

		// If there are multiple candidates with the same max distance, pick the one with the fewest occurrences
		var selectedTuple QuorumTuple
		if len(candidates) == 1 {
			selectedTuple = candidates[0]
		} else {
			minOccurrences := int(^uint(0) >> 1) // Set to max possible int value
			for _, candidate := range candidates {
				// Count occurrences of nodes in the candidate tuple
				occurrences := 0
				for _, node := range candidate {
					occurrences += nodeOccurrences[node]
				}
				// Pick the candidate with the fewest occurrences
				if occurrences < minOccurrences {
					minOccurrences = occurrences
					selectedTuple = candidate
				}
			}
		}

		// Add the selected tuple to the ordered list
		orderedTuples = append(orderedTuples, selectedTuple)

		// Update node occurrences for the selected tuple
		for _, node := range selectedTuple {
			nodeOccurrences[node]++
		}

		// Remove the selected tuple from the remaining tuples
		*tuples = removeTuple(*tuples, selectedTuple)
	}
	return orderedTuples
}

func containsNode(q QuorumTuple, node int) bool {
	for _, n := range q {
		if n == node {
			return true
		}
	}
	return false
}

// Distance calculates the Euclidean Distance between two quorum tuples
func Distance(t1, t2 QuorumTuple) int {
	if len(t1) != len(t2) {
		panic("Vectors must have the same dimension for distance calculation")
	}

	var dist = 0
	for _, node := range t1 {
		if !containsNode(t2, node) {
			dist++
		}
	}
	return dist
}

// createOrderedQuorums generates quorum combinations and orders them
func createOrderedQuorums(numNodes, quorumSize int) []QuorumTuple {
	quorumCombos := combinations(1, numNodes, quorumSize)
	return MaximizeDistanceOrdering(&quorumCombos)
}

// getMyOrdering returns the ordering for the current node and the critical length
func getMyOrdering(myPid int, orderedQuorums []QuorumTuple) []bool {
	totalLen := len(orderedQuorums)
	ordering := make([]bool, totalLen)
	for entryId, q := range orderedQuorums {
		if contains(q, myPid) {
			ordering[entryId] = true
		} else {
			ordering[entryId] = false
		}
	}
	return ordering
}

// Helper function to generate combinations
func combinations(start, end, quorumSize int) []QuorumTuple {
	result := []QuorumTuple{}
	comb := make([]int, quorumSize)
	var combine func(int, int)
	combine = func(start, depth int) {
		if depth == quorumSize {
			temp := make(QuorumTuple, quorumSize)
			copy(temp, comb)
			result = append(result, temp)
			return
		}
		for i := start; i <= end; i++ {
			comb[depth] = i
			combine(i+1, depth+1)
		}
	}
	combine(start, 0)
	return result
}

// Helper function to check if a QuorumTuple contains a specific NodeId
func contains(q QuorumTuple, pid int) bool {
	for _, id := range q {
		if id == pid {
			return true
		}
	}
	return false
}

// Helper function to remove a specific QuorumTuple from a slice of QuorumTuples
func removeTuple(tuples []QuorumTuple, tuple QuorumTuple) []QuorumTuple {
	for i, t := range tuples {
		if Equal(t, tuple) {
			return append(tuples[:i], tuples[i+1:]...)
		}
	}
	return tuples
}

// Helper function to compare two QuorumTuples
func Equal(t1, t2 QuorumTuple) bool {
	if len(t1) != len(t2) {
		return false
	}
	for i := range t1 {
		if t1[i] != t2[i] {
			return false
		}
	}
	return true
}

// NewMetronome Metronome factory function to create a new Metronome instance
func NewMetronome(pid int, numNodes, quorumSize int) *Metronome {
	assertTrue(numNodes > 0, "Number of nodes must be greater than 0")
	assertTrue(quorumSize > 0, "Quorum size must be greater than 0")
	assertTrue(numNodes >= quorumSize, "Number of nodes must be greater than or equal to quorum size")
	assertTrue(pid > 0, "Node ID must be greater than 0")
	orderedQuorums := createOrderedQuorums(numNodes, quorumSize)
	ordering := getMyOrdering(pid, orderedQuorums)
	var criticalLen = 0
	for _, willFlush := range ordering {
		if willFlush {
			criticalLen++
		}
	}
	totalLen := len(ordering)
	ratio := float64(criticalLen) / float64(totalLen)
	return &Metronome{
		Pid:                pid,
		MyCriticalOrdering: ordering,
		CriticalLen:        criticalLen,
		TotalLen:           totalLen,
		Ratio:              ratio,
	}
}
