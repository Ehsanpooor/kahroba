package main

import (
	"bytes"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"mime"
	"net"
	"net/smtp"
	"os"
	"strings"
	"time"
)

// mailer.go — sending an email through an ordinary mail account (SMTP).
//
// Any provider works: Zoho Mail, ZeptoMail, Gmail with an app password, or
// another. The account is set in the server's environment:
//
//	SMTP_HOST      smtp.zoho.com, smtp.zeptomail.com, smtp.gmail.com …
//	SMTP_PORT      465 (TLS from the start) or 587 / 2525 (STARTTLS); a list
//	               such as "587,2525" is tried in order
//	SMTP_USER      the login
//	SMTP_PASSWORD  its password or app password
//	SMTP_FROM      the sender address, e.g. no-reply@aizood.ir
//	SMTP_FROM_NAME the sender name (default: Splendor)
//	SMTP_HEADERS   extra headers, "Name: value; Name: value" (Mailerino
//	               wants "IsTransactional: True")
//	SMTP_UNSUBSCRIBE  the provider's unsubscribe tag (Mailerino: {unsubscribe});
//	               when set, each email ends with a small link line using it
//
// Without SMTP_HOST the server runs normally and the email RPCs answer
// "unavailable". SMTP_HOST=log (local testing only) prints each message to
// the server's output instead of sending it.

type smtpConfig struct {
	Host, Port, User, Password, From, FromName, Headers, Unsubscribe string
}

func mailConfig() smtpConfig {
	c := smtpConfig{
		Host:        strings.TrimSpace(os.Getenv("SMTP_HOST")),
		Port:        strings.TrimSpace(os.Getenv("SMTP_PORT")),
		User:        strings.TrimSpace(os.Getenv("SMTP_USER")),
		Password:    os.Getenv("SMTP_PASSWORD"),
		From:        strings.TrimSpace(os.Getenv("SMTP_FROM")),
		FromName:    strings.TrimSpace(os.Getenv("SMTP_FROM_NAME")),
		Headers:     strings.TrimSpace(os.Getenv("SMTP_HEADERS")),
		Unsubscribe: strings.TrimSpace(os.Getenv("SMTP_UNSUBSCRIBE")),
	}
	if c.Port == "" {
		c.Port = "465"
	}
	if c.From == "" {
		c.From = c.User
	}
	if c.FromName == "" {
		c.FromName = "Splendor"
	}
	return c
}

func (c smtpConfig) ready() bool {
	return c.Host == "log" || (c.Host != "" && c.User != "" && c.Password != "" && c.From != "")
}

// mailSender sends one message; tests replace it.
var mailSender = sendMail

// sendMail sends a message with a plain text and an HTML part.
func sendMail(to, subject, text, html string) error {
	c := mailConfig()
	if !c.ready() {
		return fmt.Errorf("smtp not configured")
	}
	if c.Host == "log" {
		fmt.Printf("SMTP_HOST=log: to %s: %s\n", to, subject)
		return nil
	}
	msg := buildMessage(c, to, subject, text, html)
	// Networks in Iran block mail ports now and then (465 often stalls in the
	// TLS handshake): SMTP_PORT may list several, tried in order.
	var errs []string
	for _, port := range strings.Split(c.Port, ",") {
		port = strings.TrimSpace(port)
		if port == "" {
			continue
		}
		err := sendVia(c, port, to, msg)
		if err == nil {
			return nil
		}
		errs = append(errs, port+": "+err.Error())
	}
	return fmt.Errorf("%s", strings.Join(errs, "; "))
}

// sendVia delivers one message through one port: TLS from the start on 465,
// STARTTLS on the others.
func sendVia(c smtpConfig, port, to string, msg []byte) error {
	addr := net.JoinHostPort(c.Host, port)
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	tlsConf := &tls.Config{ServerName: c.Host}
	var conn net.Conn
	var err error
	if port == "465" {
		conn, err = tls.DialWithDialer(dialer, "tcp", addr, tlsConf)
	} else {
		conn, err = dialer.Dial("tcp", addr)
	}
	if err != nil {
		return err
	}
	_ = conn.SetDeadline(time.Now().Add(20 * time.Second))
	cl, err := smtp.NewClient(conn, c.Host)
	if err != nil {
		conn.Close()
		return err
	}
	defer cl.Close()
	if port != "465" {
		if ok, _ := cl.Extension("STARTTLS"); !ok {
			return fmt.Errorf("%s offers no STARTTLS", addr)
		}
		if err := cl.StartTLS(tlsConf); err != nil {
			return err
		}
	}
	if err := cl.Auth(smtp.PlainAuth("", c.User, c.Password, c.Host)); err != nil {
		return err
	}
	if err := cl.Mail(c.From); err != nil {
		return err
	}
	if err := cl.Rcpt(to); err != nil {
		return err
	}
	w, err := cl.Data()
	if err != nil {
		return err
	}
	if _, err := w.Write(msg); err != nil {
		return err
	}
	if err := w.Close(); err != nil {
		return err
	}
	return cl.Quit()
}

// buildMessage is the MIME message: UTF-8 headers, text and HTML parts.
func buildMessage(c smtpConfig, to, subject, text, html string) []byte {
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	boundary := "splendor-" + hex.EncodeToString(b)
	domain := c.From[strings.LastIndex(c.From, "@")+1:]
	var m bytes.Buffer
	fmt.Fprintf(&m, "From: %s <%s>\r\n", mime.BEncoding.Encode("utf-8", c.FromName), c.From)
	fmt.Fprintf(&m, "To: <%s>\r\n", to)
	fmt.Fprintf(&m, "Subject: %s\r\n", mime.BEncoding.Encode("utf-8", subject))
	fmt.Fprintf(&m, "Date: %s\r\n", time.Now().UTC().Format(time.RFC1123Z))
	fmt.Fprintf(&m, "Message-ID: <%s@%s>\r\n", hex.EncodeToString(b), domain)
	for _, h := range strings.Split(c.Headers, ";") {
		if k, v, ok := strings.Cut(strings.TrimSpace(h), ":"); ok && k != "" && !strings.ContainsAny(k+v, "\r\n") {
			fmt.Fprintf(&m, "%s: %s\r\n", strings.TrimSpace(k), strings.TrimSpace(v))
		}
	}
	m.WriteString("MIME-Version: 1.0\r\n")
	fmt.Fprintf(&m, "Content-Type: multipart/alternative; boundary=%q\r\n\r\n", boundary)
	for _, part := range [][2]string{{"text/plain", text}, {"text/html", html}} {
		fmt.Fprintf(&m, "--%s\r\n", boundary)
		fmt.Fprintf(&m, "Content-Type: %s; charset=UTF-8\r\n", part[0])
		m.WriteString("Content-Transfer-Encoding: base64\r\n\r\n")
		enc := base64.StdEncoding.EncodeToString([]byte(part[1]))
		for len(enc) > 76 {
			m.WriteString(enc[:76] + "\r\n")
			enc = enc[76:]
		}
		m.WriteString(enc + "\r\n")
	}
	fmt.Fprintf(&m, "--%s--\r\n", boundary)
	return m.Bytes()
}
