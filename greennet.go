package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"math"
	mrand "math/rand"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/1lann/ccserialize"
	"github.com/gin-gonic/gin"
)

type position struct {
	x int
	y int
	z int
}

type message struct {
	origin       user
	Channel      uint16  `ccserialize:"channel" json:"channel"`
	ReplyChannel uint16  `ccserialize:"reply_channel" json:"reply_channel"`
	Message      string  `ccserialize:"message" json:"message"`
	Distance     float64 `ccserialize:"distance" json:"-"`
}

type user struct {
	queue          []message
	position       position
	open           []uint16
	lastConnection time.Time
	receive        chan []message
	mutex          *sync.Mutex
	listenMutex    *sync.Mutex
}

var connectedUsers = make(map[string]user)
var connectedLock = new(sync.RWMutex)
var gen *mrand.Rand

func newUser() string {
	id := make([]byte, 32)
	_, err := rand.Read(id)
	if err != nil {
		panic(err)
	}

	idStr := base64.URLEncoding.EncodeToString(id)

	connectedLock.Lock()
	connectedUsers[idStr] = user{
		queue: nil,
		position: position{
			mrand.Intn(1<<16) - (1 << 15),
			mrand.Intn(255),
			mrand.Intn(1<<16) - (1 << 15),
		},
		open:           nil,
		lastConnection: time.Now(),
		receive:        make(chan []message),
		mutex:          new(sync.Mutex),
		listenMutex:    new(sync.Mutex),
	}
	connectedLock.Unlock()

	return idStr
}

func register(c *gin.Context) {
	id := newUser()
	c.String(http.StatusOK, ccserialize.Serialize(gin.H{
		"user": id,
	}))
}

func validateLockUser(c *gin.Context) (string, user) {
	id := c.PostForm("user")

	connectedLock.RLock()
	u, ok := connectedUsers[id]
	connectedLock.RUnlock()
	if !ok {
		c.AbortWithStatus(http.StatusNotAcceptable)
		return "", user{}
	}

	u.mutex.Lock()

	return id, u
}

func updateUser(id string, u user) {
	connectedLock.Lock()
	connectedUsers[id] = u
	connectedLock.Unlock()
}

func open(c *gin.Context) {
	id, u := validateLockUser(c)
	if c.IsAborted() {
		return
	}

	defer u.mutex.Unlock()

	var channels []uint16
	err := json.Unmarshal([]byte(c.PostForm("data")), &channels)
	if err != nil {
		c.AbortWithStatus(http.StatusNotAcceptable)
		return
	}

	if len(channels) > 255 {
		c.AbortWithStatus(http.StatusNotAcceptable)
		return
	}

	u.open = channels
	updateUser(id, u)
	c.String(http.StatusOK, "ok")
}

func listen(c *gin.Context) {
	id, u := validateLockUser(c)
	if c.IsAborted() {
		return
	}

	u.lastConnection = time.Now()

	if len(u.queue) > 0 {
		c.String(http.StatusOK, ccserialize.Serialize(u.queue))

		u.queue = nil
		updateUser(id, u)
		u.mutex.Unlock()
		return
	}

	updateUser(id, u)
	u.mutex.Unlock()

	u.listenMutex.Lock()
	defer u.listenMutex.Unlock()

	select {
	case messages := <-u.receive:
		c.String(http.StatusOK, ccserialize.Serialize(messages))
		return
	case <-time.After(time.Second * 20):
		c.String(http.StatusOK, ccserialize.Serialize([]message{}))
		return
	}
}

func transmit(c *gin.Context) {
	id, u := validateLockUser(c)
	if c.IsAborted() {
		return
	}

	u.mutex.Unlock()

	fmt.Println(c.PostForm("data"))

	var messages []message
	err := json.Unmarshal([]byte(c.PostForm("data")), &messages)
	if err != nil {
		c.AbortWithStatus(http.StatusNotAcceptable)
		return
	}

	for _, msg := range messages {
		msg.origin = u

		for ci, cu := range connectedUsers {
			if ci == id {
				continue
			}

			cu.mutex.Lock()
			for _, openChannel := range cu.open {
				if openChannel == msg.Channel {
					msg.Distance = getDist(cu.position, msg.origin.position)
					cu.queue = append(cu.queue, msg)
				}
			}

			select {
			case cu.receive <- cu.queue:
			default:
				updateUser(ci, cu)
			}

			cu.mutex.Unlock()
		}
	}

	c.String(http.StatusOK, "ok")
}

func getDist(a position, b position) float64 {
	return math.Sqrt(float64((a.x-b.x)*(a.x-b.x) + (a.y-b.y)*(a.y-b.y) + (a.z-b.z)*(a.z-b.z)))
}

func janitor() {
	c := time.Tick(1 * time.Minute)
	for _ = range c {
		connectedLock.Lock()

		for id, u := range connectedUsers {
			u.mutex.Lock()
			if time.Since(u.lastConnection) > time.Minute {
				delete(connectedUsers, id)
			}
			u.mutex.Unlock()
		}

		connectedLock.Unlock()
	}
}

func main() {
	gen = mrand.New(mrand.NewSource(time.Now().UnixNano()))

	r := gin.Default()
	r.GET("/register", register)
	r.POST("/open", open)
	r.POST("/listen", listen)
	r.POST("/transmit", transmit)
	r.StaticFile("/", os.Getenv("GOPATH")+"/src/github.com/1lann/greennet/greennet.lua")

	go janitor()

	gin.SetMode(gin.ReleaseMode)

	log.Fatal(r.Run(":9001"))
}
