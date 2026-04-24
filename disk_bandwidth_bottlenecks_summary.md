# Analysis of Disk Bandwidth Bottlenecks in Distributed Consensus Databases

Distributed databases utilizing consensus protocols such as **Paxos** or **Raft** rely on a replicated, persistent log to ensure data consistency and durability across a cluster. While network latency is often cited as a primary concern, disk bandwidth frequently becomes the definitive bottleneck for end-to-end performance.

This document summarizes three critical scenarios where disk throughput improvements directly translate to performance gains.

---

## 1. High-Volume Sequential Log Appends (The IOPS Wall)
In write-heavy workloads, every transaction must be appended to a **Write-Ahead Log (WAL)** and flushed to physical media using `fsync`.

* **The Constraint:** This scenario is characterized by a high volume of small write operations. Even with SSDs, the latency of confirming each `fsync` creates backpressure on the consensus engine.
* **The Bottleneck:** The system hits an **IOPS (Input/Output Operations Per Second)** limit. The disk controller struggles to process the sheer number of distinct write-and-flush commands.
* **Performance Gain:** Optimizations like **Log Striping** (parallelizing log writes across multiple disks) or **Group Commit** (batching multiple client requests into a single physical disk sync) drastically reduce the "Wait for Fsync" time.

## 2. Large Payload Handling (The Throughput Wall)
Unlike high-frequency metadata updates, this scenario involves storing large blobs, complex JSON documents, or binary data directly within the database.

* **The Constraint:** Each log entry is massive. The primary metric shifts from IOPS to raw **Throughput (MB/s or GB/s)**.
* **The Bottleneck:** The physical data bus or the NAND flash's internal write speed becomes saturated. Moving massive chunks of data from RAM to the storage medium limits the rate at which the consensus leader can propose new entries.
* **Performance Gain:** High-bandwidth NVMe drives and optimizations like **Log/Data Separation** (storing pointers in the Raft log while offloading the payload to a separate high-speed store) allow for significantly higher data ingestion rates.

### Comparison: Scenario 1 vs. Scenario 4
The table below highlights the differences in stress patterns on the storage subsystem.

| Scenario 1: High-Volume Appends | Scenario 4: Large Payloads |
| :--- | :--- |
| **IOPS** (Input/Output Operations Per Second) | **Throughput** (MB/s or GB/s) |
| The `fsync` latency. | The physical bus/NAND speed. |
| CPU overhead from context switches. | Memory pressure from large buffers. |
| **Group Commit** (Batching writes). | **Sidelining** (Off-log blob storage). |

*(Note: Feature column omitted per formatting preference.)*

---

## 3. Multi-Raft and Shard Contention
Modern distributed databases (e.g., CockroachDB, TiDB) distribute data across hundreds or thousands of "shards" or "ranges," each governed by its own independent Raft group.

* **The Constraint:** A single physical node often hosts many Raft leaders. Each leader maintains its own logical log.
* **The Bottleneck:** **I/O Contention**. While a single log is sequential, 500 concurrent logs being written to the same physical disk appear as **Random I/O** to the hardware. This causes "Seek Penalty" (even on NVMe) and high write amplification.
* **The Impact:** Individual Raft groups experience jitter and unpredictable tail latency ($P99$) because they are competing for the same disk head or controller bandwidth.
* **Performance Gain:** Implementing a **Unified Log Store**—which multiplexes many logical Raft streams into a single physical append-only stream—restores sequential write performance and allows the disk to operate at its maximum rated speed.

---

## Summary of Optimization Impact
Improving disk throughput in these areas provides a three-fold benefit:
1.  **Lower Latency:** Faster consensus rounds by reducing the time spent waiting for hardware persistence.
2.  **Higher Throughput:** Increased capacity to handle either thousands of small users or fewer high-bandwidth users.
3.  **Stability:** Better isolation between foreground consensus operations and background maintenance tasks (like LSM-Tree compactions).
